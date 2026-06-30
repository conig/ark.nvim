use std::sync::Once;

use harp::environment::R_ENVS;
use tree_sitter::Point;

static INIT: Once = Once::new();

pub fn r_test_init() {
    harp::fixtures::r_test_init();
    INIT.call_once(initialize_lsp_test_helpers);
}

fn initialize_lsp_test_helpers() {
    harp::source_str_in(LSP_TEST_HELPERS, R_ENVS.global).unwrap();
}

pub fn point_from_cursor(x: &str) -> (String, Point) {
    let (text, point, _offset) = point_and_offset_from_cursor(x, b'@');
    (text, point)
}

pub fn point_and_offset_from_cursor(x: &str, cursor: u8) -> (String, Point, usize) {
    let lines = x.split('\n').collect::<Vec<&str>>();

    let mut offset = 0;

    let cursor_for_replace = [cursor];
    let cursor_for_replace = str::from_utf8(&cursor_for_replace).unwrap();

    for (line_row, line) in lines.into_iter().enumerate() {
        for (char_column, char) in line.as_bytes().iter().enumerate() {
            if char == &cursor {
                let x = x.replace(cursor_for_replace, "");
                let point = Point {
                    row: line_row,
                    column: char_column,
                };
                offset += char_column;
                return (x, point, offset);
            }
        }
        offset += line.len() + 1;
    }

    panic!("`x` must include a `@` character!");
}

pub fn package_is_installed(package: &str) -> bool {
    harp::parse_eval_global(format!(".ps.is_installed({package:?})").as_str())
        .unwrap()
        .try_into()
        .unwrap()
}

const LSP_TEST_HELPERS: &str = r#"
options(ark.testing = TRUE)

`%??%` <- function(x, y) {
    if (is.null(x)) y else x
}

.ps.is_installed <- function(pkg, minimum_version = NULL) {
    installed <- system.file(package = pkg) != ""

    if (installed && !is.null(minimum_version)) {
        installed <- utils::packageVersion(pkg) >= minimum_version
    }

    installed
}

.ps.help.getHtmlHelpContents <- function(topic, package = NULL) {
    if (grepl(":{2,3}", topic)) {
        parts <- strsplit(topic, ":{2,3}")[[1L]]
        package <- parts[[1L]]
        topic <- parts[[2L]]
    }

    help_files <- utils::help(topic = (topic), package = (package), help_type = "html")
    if (length(help_files) == 0) {
        return(NULL)
    }

    help_file <- help_files[[1L]]
    rd <- utils:::.getHelpFile(help_file)

    if (is.null(package)) {
        path_help <- dirname(help_file)
        path_package <- dirname(path_help)

        if (file.exists(path_package)) {
            package <- basename(path_package)
        }
    }

    if (is.null(package)) {
        package <- ""
    }

    html_file <- tempfile(fileext = ".html")
    on.exit(unlink(html_file), add = TRUE)

    tools::Rd2HTML(rd, out = html_file, package = package)
    paste(readLines(html_file, warn = FALSE), collapse = "\n")
}

.ps.completions.formalNamesDefault <- function(callable) {
    args <- args(callable)
    if (!is.function(args)) {
        return(character())
    }

    names(formals(args))
}

.ps.s3.genericNameFromFunction <- function(callable) {
    use_method <- as.name("UseMethod")

    recursive_search <- function(object) {
        if (
            is.call(object) &&
                length(object) >= 2L &&
                identical(object[[1L]], use_method) &&
                is.character(object[[2L]])
        ) {
            return(object[[2L]])
        }

        if (is.recursive(object)) {
            for (i in seq_along(object)) {
                result <- recursive_search(object[[i]])
                if (!is.null(result)) {
                    return(result)
                }
            }
        }

        NULL
    }

    as.character(recursive_search(body(callable)))
}

.ps.completions.formalNamesS3 <- function(generic, object) {
    classes <- c(class(object), "default")

    for (class in classes) {
        call <- substitute(
            utils::getS3method(generic, class, optional = TRUE),
            list(generic = generic, class = class)
        )

        method <- eval(call, envir = globalenv())
        if (is.function(method)) {
            return(.ps.completions.formalNamesDefault(method))
        }
    }

    character()
}

.ps.completions.formalNames <- function(callable, object) {
    if (is.null(object)) {
        return(.ps.completions.formalNamesDefault(callable))
    }

    generic <- .ps.s3.genericNameFromFunction(callable)
    if (length(generic)) {
        return(.ps.completions.formalNamesS3(generic, object))
    }

    .ps.completions.formalNamesDefault(callable)
}

.ps.completions.createCustomCompletions <- function(
    values,
    kind = "unknown",
    enquote = FALSE,
    append = ""
) {
    list(
        as.character(values),
        as.character(kind),
        as.logical(enquote),
        as.character(append)
    )
}

customCompletionHandlers <- new.env(parent = emptyenv())

.ps.completions.registerCustomCompletionHandler <- function(
    package,
    name,
    argument,
    callback
) {
    all_names <- c(
        name,
        paste(package, name, sep = "::"),
        paste(package, name, sep = ":::")
    )

    for (name in all_names) {
        spec <- paste(name, argument)
        customCompletionHandlers[[spec]] <- callback
    }
}

.ps.completions.registerCustomCompletionHandler(
    "base",
    "library",
    "package",
    function(position) {
        .ps.completions.createCustomCompletions(
            values = .packages(TRUE),
            kind = "package",
            enquote = FALSE,
            append = ""
        )
    }
)

.ps.completions.registerCustomCompletionHandler(
    "base",
    "getOption",
    "x",
    function(position) {
        .ps.completions.createCustomCompletions(
            values = names(options()),
            kind = "options",
            enquote = TRUE,
            append = ""
        )
    }
)

.ps.completions.registerCustomCompletionHandler(
    "base",
    "options",
    "...",
    function(position) {
        if (position != "name") {
            return(NULL)
        }

        .ps.completions.createCustomCompletions(
            values = names(options()),
            kind = "options",
            enquote = FALSE,
            append = " = "
        )
    }
)

.ps.completions.registerCustomCompletionHandler(
    "base",
    "Sys.getenv",
    "x",
    function(position) {
        .ps.completions.createCustomCompletions(
            values = names(Sys.getenv()),
            kind = "unknown",
            enquote = TRUE,
            append = ""
        )
    }
)

.ps.completions.registerCustomCompletionHandler(
    "base",
    "Sys.unsetenv",
    "x",
    function(position) {
        .ps.completions.createCustomCompletions(
            values = names(Sys.getenv()),
            kind = "unknown",
            enquote = TRUE,
            append = ""
        )
    }
)

.ps.completions.registerCustomCompletionHandler(
    "base",
    "Sys.setenv",
    "...",
    function(position) {
        if (position != "name") {
            return(NULL)
        }

        .ps.completions.createCustomCompletions(
            values = names(Sys.getenv()),
            kind = "unknown",
            enquote = FALSE,
            append = " = "
        )
    }
)

.ps.completions.getCustomCallCompletions <- function(name, argument, position) {
    index <- regexpr(name, "::", fixed = TRUE)
    if (as.integer(index) != -1L) {
        package <- substring(name, 1L, index - 1L)
        if (!package %in% loadedNamespaces()) {
            return(NULL)
        }
    }

    spec <- paste(name, argument)
    handler <- customCompletionHandlers[[spec]]
    if (is.function(handler)) {
        return(handler(position))
    }

    NULL
}
"#;
