// clawd-dictate.app launcher — a tiny binary that EMBEDS Python and runs
// ../dictate.py from the repo checkout beside the bundle.
//
// Why not just run python: macOS keys Microphone / Accessibility / Input
// Monitoring permissions to the process's main executable. A bare `python`
// is indistinguishable from every other script on the machine, and the grant
// dies whenever the interpreter updates. This binary IS the app: its own
// bundle id, its own name in System Settings, and it never changes when
// dictate.py does (git pull updates the script, the signature stays) — so a
// permission granted once stays granted.
//
// Built by install.sh with clang + the python3.13 framework (--embed flags).
#include <Python.h>
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static void die(const char *msg) { fprintf(stderr, "clawd-dictate launcher: %s\n", msg); exit(1); }

int main(int argc, char **argv) {
    // where am I: <repo>/clawd-dictate.app/Contents/MacOS/clawd-dictate → <repo>
    char exe[PATH_MAX]; uint32_t n = sizeof(exe);
    if (_NSGetExecutablePath(exe, &n) != 0) die("executable path too long");
    char real[PATH_MAX];
    if (!realpath(exe, real)) die("realpath failed");
    char repo[PATH_MAX];
    strlcpy(repo, real, sizeof(repo));
    for (int i = 0; i < 4; i++) { char *d = dirname(repo); if (d != repo) strlcpy(repo, d, sizeof(repo)); }   // MacOS, Contents, .app, → repo
    const char *override = getenv("CLAWD_DICTATE_REPO");
    if (override && *override) strlcpy(repo, override, sizeof(repo));

    char script[PATH_MAX], venv[PATH_MAX];
    snprintf(script, sizeof(script), "%s/dictate.py", repo);
    snprintf(venv, sizeof(venv), "%s/.venv/lib/python%d.%d/site-packages", repo, PY_MAJOR_VERSION, PY_MINOR_VERSION);

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.parse_argv = 0;
    PyStatus st = PyConfig_SetBytesString(&config, &config.program_name, real);
    if (PyStatus_Exception(st)) die("program name");
    // argv[0] = the script path, so dictate.py sees itself the normal way
    char *pyargv[argc + 1];
    pyargv[0] = script;
    for (int i = 1; i < argc; i++) pyargv[i] = argv[i];
    st = PyConfig_SetBytesArgv(&config, argc, pyargv);
    if (PyStatus_Exception(st)) die("argv");
    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) die("python init failed");

    // the venv's packages + the repo, then run the script as __main__
    char pre[PATH_MAX * 3];
    snprintf(pre, sizeof(pre),
        "import sys, os\nsys.path.insert(0, r'''%s''')\nsys.path.insert(0, r'''%s''')\nos.environ.setdefault('CLAWD_DICTATE_BUNDLED', '1')\n",
        venv, repo);
    if (PyRun_SimpleString(pre) != 0) die("path setup failed");

    FILE *fp = fopen(script, "r");
    if (!fp) { fprintf(stderr, "clawd-dictate launcher: cannot open %s\n", script); return 1; }
    int rc = PyRun_SimpleFileEx(fp, script, 1);   // closes fp
    if (Py_FinalizeEx() < 0) rc = 120;
    return rc;
}
