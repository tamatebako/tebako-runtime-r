/*
 * THIS FILE IS A TEMPLATE — the factory generates src/main/tebako_r_main.c
 * from it (RBuild#write_fs_tu), substituting @MOUNT_ROOT@; the generated
 * copy is the R @R_VERSION@ build's fs TU.
 *
 * The tebako R fs TU (translation unit): the runtime exe's real main(),
 * linked INTO the R interpreter binary src/main/R.bin (the ruby/python/
 * php pattern — README's LINKED-driver decision). R's own entry point
 * (src/main/Rmain.c's main) is renamed r_main at COMPILE time (the
 * generated src/main/Makefile gains an explicit Rmain.o rule with
 * -Dmain=r_main — a build-file substitution, never a source patch). This
 * TU provides main and forwards to r_main after the boot.
 *
 * Why R.bin and not Rscript: upstream's Rscript (src/unix/Rscript.c) is
 * a tiny launcher that execv()s <R_HOME>/bin/R — a SHELL script, which
 * execs R_HOME/bin/exec/R (= this binary) in turn. A script inside the
 * VFS cannot be exec'd (the kernel's #! read never reaches the preload
 * shim), so the launcher shape cannot survive the mount. The tebako exe
 * therefore IS the interpreter (R.bin), and this TU carries the Rscript
 * front-end in C: the argv translation below ports Rscript.c's semantics
 * (--no-echo --no-restore prepended; -e pairs through; --verbose;
 * --default-packages=X; the first bare argument becomes --file=<arg>,
 * the rest follow --args; R_SCRIPT_DEFAULT_PACKAGES / R_SCRIPT_LEGACY
 * env precedence; lone --help/--version print and exit WITHOUT touching
 * R). The version banner reads the generated <Rversion.h> — the same
 * header upstream Rscript.c prints from (tools/GETVERSION from VERSION +
 * SVN-REVISION), so the banner can never drift from the interpreter.
 *
 * The exe merges upstream's TWO entry binaries, so the front-end is a
 * discriminator first (rscript_shape): invoked the INTERPRETER's way —
 * only dashed options, no bare token Rscript would take as its file, no
 * Rscript-only flag — the argv is exec/R's own and passes through
 * untouched. Upstream exec/R reads stdin when no --file names a script,
 * and R's own build leans on exactly that: basepkg.mk pipes generated
 * code into `bin/R --vanilla --no-echo` (= exec/R = this binary) for
 * every lazy-load DB and sysdata.rda, and the Rscript front-end would
 * demand a file and die "file name is missing" there. The driver's
 * handoff always arrives the OTHER way — spec 17 rewrites argv to the
 * interpreter convention (the resolved entry as the script arg, then
 * the user's args verbatim) — so a bare-led argv is the Rscript shape
 * and translates. -e pairs work on both arms (exec/R evaluates them
 * natively; the translation prepends its defaults when the shape says
 * Rscript).
 *
 * The interpreter is UNPATCHED (no tamatebako R source factory exists,
 * so this factory fetches pristine CRAN tarballs): R's own libc file IO
 * cannot see the driver's mounts. The visibility story is spec 22's
 * tier-1 preload interposition, composed in two process incarnations
 * (the tebako-runtime-php/-python model):
 *
 *   1. the FIRST incarnation boots the driver in-process
 *      (tebako_driver_boot — mounts the env image from
 *      TEBAKO_RUNTIME_IMAGE and every --tebako-image payload triple,
 *      verifies the layout card, applies the jail, rewrites argv to the
 *      resolved entry, and arms the preload-shim injection env from the
 *      image's layout grant). A preload library binds only at exec, so —
 *   2. when the boot mounted anything, main re-execs ITSELF with the
 *      Rscript-translated argv and the driver-armed env (LD_PRELOAD +
 *      TEBAKO_PRELOAD_SHIM + TEBAKO_TFS_MOUNTS). The shim's constructor
 *      re-mounts the serialized mount table in the child; the child
 *      (sentinel set) skips the boot and runs r_main, whose libc IO the
 *      shim now serves from the VFS.
 *
 * R_HOME: exec/R locates its home from the R_HOME environment variable
 * (src/main/sysutils.c R_HomeDir); with it unset the interpreter dies
 * "R home directory is not defined". When the env image is mounted this
 * TU exports R_HOME=<effective root>/lib/R, where the effective root is
 * the driver's validated TEBAKO_MOUNT_ROOT override when given, else the
 * baked mount point (the tebako-runtime-python fs TU's PYTHONHOME
 * pattern). Bare boots (TEBAKO_RUNTIME_IMAGE unset) leave R_HOME alone —
 * exec/R's own message names the failure, and the lone --help/--version
 * fast paths still work bare (upstream Rscript semantics: they never
 * touch R).
 *
 * Boot contract (exit codes are the driver's, surfaced unmodified — the
 * same named errors the other runtimes produce): TEBAKO_MOUNT_ROOT
 * malformed -> 65 (driver-validated pre-mount); ungranted override -> 78
 * (the layout pair check); a mounted image with no preload_shim grant ->
 * 78 (below: the interpreter would boot blind). Front-end failures keep
 * upstream Rscript's codes (usage/translation errors exit 1); the re-exec
 * machinery's failures are the loader's named codes (74).
 *
 * Deliberate deltas from upstream Rscript.c (documented, not silent):
 * R_ARCH defaulting is dropped (Rscript passes its compile-time
 * sub-architecture through; the tebako exe ships one architecture per
 * artifact, so there is no sub-architecture to default), and putenv is
 * setenv (no live-string bookkeeping; exec semantics unchanged).
 *
 * Scope: the POSIX legs (linux ELF + macOS — the preload-shim tier 1
 * platforms). Windows (the spec 17 §7 materialize tier — there is no
 * preload tier on windows) arrives with its leg.
 */

/* glibc AND musl under -std=gnu11 hide readlink/setenv behind feature-test
 * macros; _GNU_SOURCE exposes them. Must precede every system include. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h> /* _NSGetExecutablePath */
#endif

#include <Rversion.h> /* generated by the build (tools/GETVERSION) */

#ifndef PATH_MAX
#define PATH_MAX 5000 /* upstream Rscript.c's fallback */
#endif

/* The spec-17 driver ABI (tamatebako/tebako crates/tebako-driver ffi.rs). */
extern int tebako_driver_boot(int *argc, char ***argv, const char *runtime_root);
extern const char *tebako_mount_point(void);
extern unsigned int tebako_driver_contract_version(void);

/* R's entry point: src/main/Rmain.c's main, renamed at compile time (the
 * header comment). */
extern int r_main(int argc, char **argv);

/* The mount root this runtime was compiled against. OWNER: this factory
 * (R carries no patch literals to flow it from); the env image's layout
 * card declares the same value, emitted from the same constant in the
 * same build. */
static const char tebako_r_mount_root[] = "@MOUNT_ROOT@";

/* The re-exec sentinel (the header comment). */
#define TEBAKO_R_BOOTED "TEBAKO_R_BOOTED"

/* The running executable's own path for the re-exec: /proc on linux,
 * _NSGetExecutablePath on macOS. argv[0] as the last resort elsewhere
 * when it carries a path separator. A failure is a named error, never a
 * PATH guess. */
static int self_executable_path(char *buf, size_t cap, const char *argv0) {
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, cap - 1);
    if (n <= 0 || (size_t)n >= cap - 1)
        return -1;
    buf[n] = '\0';
    return 0;
#elif defined(__APPLE__)
    /* _NSGetExecutablePath may return a symlink-laden spelling;
     * realpath resolves it (and normalizes into buf). */
    {
        char raw[PATH_MAX];
        uint32_t size = (uint32_t)sizeof raw;
        if (_NSGetExecutablePath(raw, &size) != 0)
            return -1;
        return realpath(raw, buf) != NULL ? 0 : -1;
    }
#else
    (void)cap;
    if (strchr(argv0, '/') != NULL && realpath(argv0, buf) != NULL)
        return 0;
    return -1;
#endif
}

/* Upstream Rscript.c's usage(), verbatim (stdout, and the lone --help /
 * argc<=1 paths keep upstream's exit codes 0 and 1 respectively). */
static void rscript_usage(void) {
    fprintf(stdout, "Usage: Rscript [options] file [args]\n");
    fprintf(stdout, "   or: Rscript [options] -e expr [-e expr2 ...] [args]\n");
    fprintf(stdout, "A binary front-end to R, for use in scripting applications.\n\n");
    fprintf(stdout, "Options:\n");
    fprintf(stdout, "  --help              Print usage and exit\n");
    fprintf(stdout, "  --version           Print version and exit\n");
    fprintf(stdout, "  --verbose           Print information on progress\n");
    fprintf(stdout, "  --default-packages=LIST  Attach these packages on startup;\n");
    fprintf(stdout, "                        a comma-separated LIST of package names, or 'NULL'\n");
    fprintf(stdout, "and options to R (in addition to --no-echo --no-restore), for example:\n");
    fprintf(stdout, "  --save              Do save workspace at the end of the session\n");
    fprintf(stdout, "  --no-environ        Don't read the site and user environment files\n");
    fprintf(stdout, "  --no-site-file      Don't read the site-wide Rprofile\n");
    fprintf(stdout, "  --no-init-file      Don't read the user R profile\n");
    fprintf(stdout, "  --restore           Do restore previously saved objects at startup\n");
    fprintf(stdout, "  --vanilla           Combine --no-save, --no-restore, --no-site-file,\n");
    fprintf(stdout, "                        --no-init-file and --no-environ\n");
    fprintf(stdout, "\nExpressions (one or more '-e <expr>') may be used *instead* of 'file'.\n");
    fprintf(stdout, "Any additional 'args' can be accessed from R via 'commandArgs(TRUE)'.\n");
    fprintf(stdout, "See also  ?Rscript  from within R.\n");
}

/* Upstream Rscript.c's lone --version banner, verbatim (the release
 * shape: R_STATUS is empty in a release tarball). */
static void rscript_version(void) {
    if (strlen(R_STATUS) == 0)
        fprintf(stdout, "Rscript (R) version %s.%s (%s-%s-%s)\n",
                R_MAJOR, R_MINOR, R_YEAR, R_MONTH, R_DAY);
    else
        fprintf(stdout, "Rscript (R) version %s.%s %s (%s-%s-%s r%d)\n",
                R_MAJOR, R_MINOR, R_STATUS, R_YEAR, R_MONTH, R_DAY,
                R_SVN_REVISION);
}

/* The translate-or-passthrough discriminator (the header comment).
 * Returns 1 when the post-boot argv is Rscript-shaped — a bare token
 * the front-end would take as its file, or an Rscript-only flag
 * (--verbose, --default-packages=) — and 0 when it is exec/R-shaped
 * (dashed options only). -e consumes its expression either way; --args
 * ends the scan (everything after it is positional in both grammars).
 * A dangling -e is Rscript-shaped so the translation reports upstream's
 * "-e not followed by an expression". */
static int rscript_shape(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-e") == 0) {
            if (i + 1 >= argc)
                return 1;
            i++; /* the expression is consumed, never a file */
            continue;
        }
        if (strcmp(argv[i], "--args") == 0)
            return 0;
        if (strncmp(argv[i], "--", 2) == 0) {
            if (strcmp(argv[i], "--verbose") == 0 ||
                strncmp(argv[i], "--default-packages=", 18) == 0)
                return 1;
            continue;
        }
        return 1; /* a bare token — Rscript's file argument */
    }
    return 0;
}

/* The Rscript front-end (the header comment): translate the post-boot
 * argv the way src/unix/Rscript.c assembles exec/R's command line,
 * in-process. Returns the translated vector in av_out/ac_out; the
 * vector and the --file= string are deliberately never freed (the
 * process either re-execs or hands them to r_main). A translation
 * failure prints upstream's message and exits 1. */
static void rscript_translate(int argc, char **argv, int *ac_out, char ***av_out) {
    char **av;
    int ac = 0, i, i0 = 0, e_mode = 0, set_dp = 0;
    int verbose = 0, have_cmdarg_default_packages = 0;

    av = (char **)malloc((size_t)(argc + 4) * sizeof(char *));
    if (!av) {
        fputs("malloc failure\n", stderr);
        exit(1);
    }

    av[ac++] = argv[0];
    av[ac++] = "--no-echo";
    av[ac++] = "--no-restore";

    /* first copy over any -e or --foo args (upstream's loop, verbatim) */
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-e") == 0) {
            e_mode = 1;
            av[ac++] = argv[i];
            if (++i >= argc) {
                fputs("-e not followed by an expression\n", stderr);
                exit(1);
            }
            av[ac++] = argv[i];
            i0 = i;
            continue;
        }
        if (e_mode)
            break; /* once in e_mode only -e options are processed;
                      remaining --options belong to the expressions (PR#18102) */
        if (strncmp(argv[i], "--", 2) != 0)
            break;
        if (strcmp(argv[i], "--verbose") == 0) {
            verbose = 1;
            i0 = i;
            continue;
        }
        /* Upstream compares 18 bytes ("--default-packages", one short of
         * the whole option) and reads the value from +19, past the
         * separator — kept byte-exact so the quirk's behavior matches. */
        if (strncmp(argv[i], "--default-packages=", 18) == 0) {
            set_dp = 1;
            if (setenv("R_DEFAULT_PACKAGES", argv[i] + 19, 1) != 0) {
                fputs("unable to set R_DEFAULT_PACKAGES\n", stderr);
                exit(1);
            }
            if (verbose)
                fprintf(stderr, "setting 'R_DEFAULT_PACKAGES=%s'\n", argv[i] + 19);
            have_cmdarg_default_packages = 1;
            i0 = i;
            continue;
        }
        av[ac++] = argv[i];
        i0 = i;
    }

    if (!e_mode) {
        if (++i0 >= argc) {
            fputs("file name is missing\n", stderr);
            exit(1);
        }
        if (strlen(argv[i0]) > (size_t)PATH_MAX) {
            fputs("file name is too long\n", stderr);
            exit(1);
        }
        {
            char *file_arg = (char *)malloc(strlen(argv[i0]) + 8);
            if (!file_arg) {
                fputs("malloc failure\n", stderr);
                exit(1);
            }
            sprintf(file_arg, "--file=%s", argv[i0]); /* sized above */
            av[ac++] = file_arg;
        }
    }
    /* copy any user arguments, preceded by "--args" */
    i = i0 + 1;
    if (i < argc) {
        av[ac++] = "--args";
        for (; i < argc; i++)
            av[ac++] = argv[i];
    }
    av[ac] = (char *)NULL;

    /* If provided, and default packages are not specified on the command
       line, then R_SCRIPT_DEFAULT_PACKAGES takes precedence over
       R_DEFAULT_PACKAGES (upstream's precedence, verbatim). */
    if (!have_cmdarg_default_packages) {
        const char *rsdp = getenv("R_SCRIPT_DEFAULT_PACKAGES");
        if (rsdp && setenv("R_DEFAULT_PACKAGES", rsdp, 1) != 0) {
            fputs("unable to set R_DEFAULT_PACKAGES\n", stderr);
            exit(1);
        }
    }

    {
        const char *legacy = getenv("R_SCRIPT_LEGACY");
        if (legacy && strcmp(legacy, "yes") == 0 && !set_dp && !getenv("R_DEFAULT_PACKAGES")) {
            if (setenv("R_DEFAULT_PACKAGES", "datasets,utils,grDevices,graphics,stats", 1) != 0) {
                fputs("unable to set R_DEFAULT_PACKAGES\n", stderr);
                exit(1);
            }
        }
    }

    if (verbose) {
        fprintf(stderr, "running\n  '%s", av[0]);
        for (i = 1; i < ac; i++)
            fprintf(stderr, " %s", av[i]);
        fputs("'\n\n", stderr);
    }

    *ac_out = ac;
    *av_out = av;
}

int main(int argc, char **argv) {
    int rc, ac = 0;
    char **av = NULL;
    char version[16];

    /* The re-exec'd child: the preload shim is armed and its constructor
     * has re-mounted the mount table — straight to the interpreter. */
    if (getenv(TEBAKO_R_BOOTED) != NULL)
        return r_main(argc, argv);

    rc = tebako_driver_boot(&argc, &argv, tebako_r_mount_root);
    if (rc != 0)
        return rc; /* the named loader error is already on stderr; nothing mounted */

    /* The runtime is authoritative for the contract it speaks (the ruby
     * driver's tebako_main behavior — the generic tebako_driver_boot
     * entry leaves the export to the caller); an inherited value is
     * always overwritten. */
    snprintf(version, sizeof version, "%u", tebako_driver_contract_version());
    setenv("TEBAKO_CONTRACT_VERSION", version, 1);

    /* The Rscript fast paths (the header comment): a lone --help or
     * --version prints and exits WITHOUT touching R — they work on a
     * bare boot, where the interpreter itself could not start. */
    if (argc == 2) {
        if (strcmp(argv[1], "--help") == 0) {
            rscript_usage();
            return 0;
        }
        if (strcmp(argv[1], "--version") == 0) {
            rscript_version();
            return 0;
        }
    }
    if (argc <= 1) {
        rscript_usage();
        return 1;
    }

    /* R_HOME off the effective mount root (the header comment). Only a
     * mounted env image has an R home to name; the bare boot leaves the
     * variable alone and exec/R names its own failure. */
    if (getenv("TEBAKO_RUNTIME_IMAGE") != NULL) {
        const char *root = getenv("TEBAKO_MOUNT_ROOT");
        char r_home[PATH_MAX];
        if (root == NULL || *root == '\0')
            root = tebako_mount_point();
        if (snprintf(r_home, sizeof r_home, "%s/lib/R", root) >= (int)sizeof r_home) {
            fputs("tebako-r: the mount root is too long to spell R_HOME\n", stderr);
            return 74;
        }
        setenv("R_HOME", r_home, 1);
    }

    /* The merged front-end (the header comment): Rscript-shaped argv
     * translates; exec/R-shaped argv passes through untouched (R's own
     * build invokes this binary that way, code piped on stdin). */
    if (rscript_shape(argc, argv))
        rscript_translate(argc, argv, &ac, &av);
    else {
        ac = argc;
        av = argv;
    }

    if (getenv("TEBAKO_TFS_MOUNTS") == NULL)
        return r_main(ac, av); /* bare boot — nothing mounted */

    if (getenv("TEBAKO_PRELOAD_SHIM") == NULL) {
        fputs("tebako-r: the env image declares no preload shim (lib/tebako/layout.yaml) — "
              "an unpatched R cannot read the mounted filesystem without it; rebuild the "
              "runtime with a link unit that ships libtfs_preload\n", stderr);
        return 78;
    }

    {
        char self[PATH_MAX];
        if (self_executable_path(self, sizeof self, argv[0]) != 0) {
            fputs("tebako-r: cannot resolve the interpreter's own path for the "
                  "preload-shim re-exec\n", stderr);
            return 74;
        }
        setenv(TEBAKO_R_BOOTED, "1", 1);
        execv(self, av);
        perror("tebako-r: re-exec under the preload shim failed");
        return 74;
    }
}
