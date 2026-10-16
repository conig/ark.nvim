# Inspect installed format definitions. Never call a renderer, force a default,
# source a document/profile, or evaluate an expression supplied by the document.
local({
    request <- jsonlite::fromJSON(commandArgs(trailingOnly = TRUE)[[1L]])
    if (length(request$libraries)) {
        .libPaths(unique(c(request$libraries, .libPaths())))
    }
    options <- list()
    metadata <- list()
    # Library roots also detect newly installed, higher-priority package copies.
    dependencies <- unique(c(request$libraries, .libPaths()))
    visited <- list()
    nodes <- 0L
    identifier <- function(x) {
        is.character(x) &&
            length(x) == 1L &&
            grepl("^[A-Za-z.][A-Za-z0-9._]*$", x)
    }
    package_namespace <- function(package) {
        if (!identifier(package)) {
            return(NULL)
        }
        sink(stderr())
        on.exit(sink(), add = TRUE)
        ns <- tryCatch(
            suppressPackageStartupMessages(loadNamespace(package)),
            error = function(e) NULL
        )
        if (!is.null(ns) && !isBaseNamespace(ns)) {
            dependencies <<- unique(c(
                dependencies,
                file.path(getNamespaceInfo(ns, "path"), "DESCRIPTION")
            ))
        }
        ns
    }
    `%||%` <- function(x, y) if (is.null(x)) y else x
    # Tiny abstract values retain only a function reference, dots provenance and
    # explicitly supplied option names. Never retain expanding expression scopes.
    abstract <- function(expr, env, scope, depth = 0L) {
        empty <- list(fn = NULL, dots = FALSE, fields = character())
        nodes <<- nodes + 1L
        if (depth > 12L || nodes > 20000L) {
            return(empty)
        }
        if (is.symbol(expr)) {
            name <- as.character(expr)
            if (name == "...") {
                return(list(fn = NULL, dots = TRUE, fields = character()))
            }
            if (!is.null(scope[[name]])) {
                return(scope[[name]])
            }
            current <- env
            while (!identical(current, emptyenv())) {
                if (exists(name, current, inherits = FALSE)) {
                    if (bindingIsActive(name, current)) {
                        return(empty)
                    }
                    value <- tryCatch(
                        get(name, current, inherits = FALSE),
                        error = function(e) NULL
                    )
                    if (is.function(value)) {
                        empty$fn <- value
                    }
                    return(empty)
                }
                current <- parent.env(current)
            }
            return(empty)
        }
        if (!is.call(expr)) {
            return(empty)
        }
        head <- if (is.symbol(expr[[1L]])) as.character(expr[[1L]]) else ""
        if (head %in% c("function", "quote", "substitute", "expression")) {
            return(empty)
        }
        if (head %in% c("::", ":::") && length(expr) == 3L) {
            package <- as.character(expr[[2L]])
            name <- as.character(expr[[3L]])
            ns <- package_namespace(package)
            if (
                is.null(ns) ||
                    !identifier(name) ||
                    !exists(name, ns, inherits = FALSE) ||
                    bindingIsActive(name, ns)
            ) {
                return(empty)
            }
            if (head == "::" && !name %in% getNamespaceExports(ns)) {
                return(empty)
            }
            value <- tryCatch(
                get(name, ns, inherits = FALSE),
                error = function(e) NULL
            )
            if (is.function(value)) {
                empty$fn <- value
            }
            return(empty)
        }
        parts <- as.list(expr)[-1L]
        values <- lapply(parts, function(part) {
            abstract(part, env, scope, depth + 1L)
        })
        empty$dots <- any(vapply(
            values,
            function(value) value$dots,
            logical(1)
        ))
        if (head == "list") {
            empty$fields <- names(parts) %||% character()
        }
        empty
    }
    resolve <- function(expr, env, scope) abstract(expr, env, scope)$fn
    literal_choices <- function(expr) {
        if (is.logical(expr) && length(expr) == 1L && !is.na(expr)) {
            return(c("true", "false"))
        }
        if (is.character(expr) && length(expr) <= 32L) {
            return(expr[nchar(expr) <= 128L])
        }
        if (is.call(expr) && identical(expr[[1L]], as.name("c"))) {
            pieces <- as.list(expr)[-1L]
            if (
                length(pieces) <= 32L &&
                    all(vapply(pieces, is.character, logical(1)))
            ) {
                return(unique(unlist(pieces, use.names = FALSE)))
            }
        }
        character()
    }
    carries_dots <- function(expr, env, scope) abstract(expr, env, scope)$dots
    fields <- function(expr, env, scope) abstract(expr, env, scope)$fields
    metadata_path <- function(expr) {
        if (identical(expr, as.name("metadata"))) {
            return(character())
        }
        if (
            !is.call(expr) ||
                length(expr) != 3L ||
                !as.character(expr[[1L]])[[1L]] %in% c("$", "[[")
        ) {
            return(NULL)
        }
        parent <- metadata_path(expr[[2L]])
        key <- expr[[3L]]
        if (is.null(parent) || !(is.symbol(key) || is.character(key))) {
            return(NULL)
        }
        key <- as.character(key)
        if (!identifier(key) || length(parent) >= 6L) {
            return(NULL)
        }
        c(parent, key)
    }
    add_metadata <- function(expr, boolean = FALSE) {
        path <- metadata_path(expr)
        if (is.null(path) || !length(path) || length(metadata) >= 256L) {
            return()
        }
        key <- paste(path, collapse = "/")
        previous <- metadata[[key]]
        boolean <- boolean || isTRUE(previous$boolean)
        metadata[[key]] <<- list(
            boolean = boolean,
            path = I(path),
            choices = if (boolean || length(previous$choices)) {
                c("true", "false")
            } else {
                character()
            }
        )
    }
    inspect <- function(
        fn,
        supplied = list(),
        excluded = character(),
        expose = TRUE,
        depth = 0L,
        stack = list()
    ) {
        if (
            !is.function(fn) ||
                is.primitive(fn) ||
                depth > 12L ||
                length(visited) >= 32L ||
                any(vapply(stack, identical, logical(1), fn))
        ) {
            return()
        }
        visited[[length(visited) + 1L]] <<- fn
        env <- environment(fn)
        if (isBaseNamespace(env)) {
            return()
        }
        if (isNamespace(env)) {
            package_namespace(getNamespaceName(env))
        }
        defaults <- as.list(formals(fn))
        scope <- list()
        for (name in names(defaults)) {
            if (identical(defaults[name], setNames(alist(x = ), name))) {
                next
            }
            scope[[name]] <- abstract(defaults[[name]], env, scope)
        }
        scope[names(supplied)] <- supplied
        if (expose) {
            for (name in setdiff(names(defaults), c("...", excluded))) {
                if (
                    length(options) >= 256L ||
                        !identifier(name) ||
                        !is.null(options[[name]])
                ) {
                    next
                }
                choices <- character()
                boolean <- FALSE
                if (!identical(defaults[name], setNames(alist(x = ), name))) {
                    default <- defaults[[name]]
                    if (is.logical(default)) {
                        choices <- literal_choices(default)
                        boolean <- length(choices) > 0L
                    }
                }
                options[[name]] <<- list(
                    path = I(name),
                    choices = I(choices),
                    boolean = boolean
                )
            }
        }
        walk <- function(expr, nested = FALSE, conditional = FALSE) {
            nodes <<- nodes + 1L
            if (nodes > 20000L || !is.call(expr)) {
                return()
            }
            head <- if (is.symbol(expr[[1L]])) as.character(expr[[1L]]) else ""
            if (head %in% c("quote", "substitute", "expression")) {
                return()
            }
            add_metadata(expr)
            if (head %in% c("!", "&&", "||", "&", "|")) {
                for (part in as.list(expr)[-1L]) {
                    add_metadata(part, TRUE)
                }
            }
            if (head %in% c("isTRUE", "isFALSE", "if") && length(expr) >= 2L) {
                add_metadata(expr[[2L]], TRUE)
            }
            if (
                head == "match.arg" &&
                    length(expr) >= 2L &&
                    is.symbol(expr[[2L]])
            ) {
                name <- as.character(expr[[2L]])
                if (!is.null(options[[name]])) {
                    choices <- if (length(expr) >= 3L) {
                        literal_choices(expr[[3L]])
                    } else if (
                        !is.null(defaults[name]) &&
                            !identical(
                                defaults[name],
                                setNames(alist(x = ), name)
                            )
                    ) {
                        literal_choices(defaults[[name]])
                    } else {
                        character()
                    }
                    if (length(choices)) options[[name]]$choices <<- choices
                }
            }
            if (head == "function") {
                walk(expr[[3L]], TRUE)
                return()
            }
            arguments <- as.list(expr)[-1L]
            if (
                !nested &&
                    !head %in%
                        c(
                            "{",
                            "(",
                            "<-",
                            "=",
                            "<<-",
                            "if",
                            "for",
                            "while",
                            "function"
                        ) &&
                    length(arguments) &&
                    any(vapply(
                        arguments,
                        function(part) carries_dots(part, env, scope),
                        logical(1)
                    ))
            ) {
                if (head == "do.call" && length(arguments) >= 2L) {
                    target <- resolve(arguments[[1L]], env, scope)
                    inspect(
                        target,
                        excluded = unique(c(
                            excluded,
                            fields(arguments[[2L]], env, scope)
                        )),
                        depth = depth + 1L,
                        stack = c(stack, list(fn))
                    )
                } else if (
                    !head %in%
                        c(
                            "{",
                            "(",
                            "<-",
                            "=",
                            "<<-",
                            "if",
                            "for",
                            "while",
                            "return",
                            "list",
                            "c"
                        )
                ) {
                    target <- resolve(expr[[1L]], env, scope)
                    if (!is.null(target)) {
                        actual_names <- names(arguments) %||%
                            rep("", length(arguments))
                        formal_names <- names(formals(target))
                        supplied <- list()
                        positional <- setdiff(
                            formal_names,
                            actual_names[nzchar(actual_names)]
                        )
                        position <- 1L
                        for (index in seq_along(arguments)) {
                            if (identical(arguments[[index]], as.name("..."))) {
                                next
                            }
                            name <- actual_names[[index]]
                            if (
                                !nzchar(name) &&
                                    position <= length(positional) &&
                                    positional[[position]] != "..."
                            ) {
                                name <- positional[[position]]
                                position <- position + 1L
                            }
                            if (nzchar(name) && name != "...") {
                                supplied[[name]] <- abstract(
                                    arguments[[index]],
                                    env,
                                    scope
                                )
                            }
                        }
                        direct <- any(vapply(
                            arguments,
                            identical,
                            logical(1),
                            as.name("...")
                        ))
                        inspect(
                            target,
                            supplied,
                            unique(c(
                                excluded,
                                names(supplied),
                                actual_names[nzchar(actual_names)]
                            )),
                            direct,
                            depth + 1L,
                            c(stack, list(fn))
                        )
                    }
                }
            }
            # Metadata helper calls are inspected without exposing their parameters.
            if (
                nested &&
                    any(vapply(
                        arguments,
                        function(part) identical(part, as.name("metadata")),
                        logical(1)
                    ))
            ) {
                inspect(
                    resolve(expr[[1L]], env, scope),
                    expose = FALSE,
                    depth = depth + 1L,
                    stack = c(stack, list(fn))
                )
            }
            for (part in arguments) {
                if (is.call(part)) {
                    walk(
                        part,
                        nested,
                        conditional ||
                            head %in% c("if", "for", "while", "switch")
                    )
                }
            }
            if (
                !nested &&
                    !conditional &&
                    head %in% c("<-", "=") &&
                    length(expr) == 3L &&
                    is.symbol(expr[[2L]])
            ) {
                scope[[as.character(expr[[2L]])]] <<- abstract(
                    expr[[3L]],
                    env,
                    scope
                )
            }
        }
        walk(body(fn))
    }
    root <- package_namespace(request$package)
    if (is.null(root)) {
        stop("renderer package unavailable")
    }
    inspect(resolve(
        call("::", as.name(request$package), as.name(request$name)),
        root,
        list()
    ))
    # Installed skeleton headers are data, not executable documents. Parsing and
    # renderer matching happen in Rust using its bounded, alias-rejecting reader.
    headers <- list()
    templates <- file.path(
        getNamespaceInfo(root, "path"),
        "rmarkdown",
        "templates"
    )
    dependencies <- unique(c(dependencies, templates))
    for (directory in head(
        list.dirs(templates, recursive = FALSE, full.names = TRUE),
        32L
    )) {
        dependencies <- unique(c(
            dependencies,
            file.path(directory, "skeleton")
        ))
        for (path in head(
            list.files(
                file.path(directory, "skeleton"),
                pattern = "\\.[Rr]md$",
                full.names = TRUE
            ),
            4L
        )) {
            size <- file.info(path)$size
            if (is.na(size) || size > 131072L || length(headers) >= 32L) {
                next
            }
            lines <- readLines(path, n = 2049L, warn = FALSE)
            if (!length(lines) || trimws(lines[[1L]]) != "---") {
                next
            }
            end <- which(trimws(lines[-1L]) %in% c("---", "..."))
            if (!length(end)) {
                next
            }
            headers[[length(headers) + 1L]] <- paste(
                lines[seq_len(end[[1L]] + 1L)],
                collapse = "\n"
            )
            dependencies <- unique(c(dependencies, path))
        }
    }
    result <- list(
        options = unname(options),
        metadata = unname(metadata),
        headers = headers,
        dependencies = I(head(dependencies, 64L))
    )
    cat(jsonlite::toJSON(
        result,
        auto_unbox = TRUE,
        null = "null",
        force = TRUE
    ))
})
