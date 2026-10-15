# One-shot inspection worker: never source a pipeline in the managed R session.
# The parent owns cancellation/deadlines; no nested callr process is necessary.
main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 2L) stop("expected request and response paths")
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("jsonlite is required for targets preview")
  response <- tryCatch({
    if (file.info(args[[1L]])$size > 65536L) stop("preview request exceeds size limit")
    request <- jsonlite::fromJSON(args[[1L]], simplifyVector = TRUE)
    if (!requireNamespace("targets", quietly = TRUE)) stop("the targets package is required for preview")
    setwd(request$root)
    if (!file.exists(request$script)) stop("targets script does not exist")
    selected <- as.character(request$names)
    max_targets <- min(2000L, max(1L, as.integer(request$max_targets)))
    max_edges <- min(5000L, max(1L, as.integer(request$max_edges)))
    started <- proc.time()[["elapsed"]]

    # Use public APIs only. Each API evaluates configuration (not target
    # commands). Fresh environments avoid leaking bindings between checks.
    # shortcut=FALSE deliberately checks upstream ancestors as well.
    network <- targets::tar_network(
      names = if (length(selected)) tidyselect::all_of(selected) else tidyselect::everything(),
      shortcut = FALSE, targets_only = TRUE, outdated = FALSE,
      reporter = "silent", callr_function = NULL,
      envir = new.env(parent = globalenv()),
      script = request$script, store = request$store
    )
    outdated <- targets::tar_outdated(
      names = if (length(selected)) tidyselect::all_of(selected) else tidyselect::everything(),
      shortcut = FALSE, targets_only = TRUE, branches = FALSE,
      reporter = "silent", callr_function = NULL,
      envir = new.env(parent = globalenv()),
      script = request$script, store = request$store
    )
    vertices <- network$vertices
    vertices$outdated <- vertices$name %in% outdated
    # Prioritize outdated targets when bounding a large result. The public
    # network API already includes last recorded seconds from store metadata.
    vertices <- vertices[order(!vertices$outdated, vertices$name), , drop = FALSE]
    shown <- utils::head(vertices, max_targets)
    edges <- utils::head(network$edges, max_edges)
    list(
      ok = TRUE, source = "targets::tar_outdated()",
      target_total = nrow(vertices), outdated_total = length(outdated),
      targets = lapply(seq_len(nrow(shown)), function(index) list(
        name = shown$name[[index]], outdated = shown$outdated[[index]],
        seconds = shown$seconds[[index]]
      )),
      edge_total = nrow(network$edges),
      edges = lapply(seq_len(nrow(edges)), function(index) list(
        from = edges$from[[index]], to = edges$to[[index]]
      )),
      targets_truncated = nrow(vertices) > max_targets,
      edges_truncated = nrow(network$edges) > max_edges,
      inconsistent = any(!outdated %in% vertices$name),
      elapsed_ms = 1000 * (proc.time()[["elapsed"]] - started)
    )
  }, error = function(error) list(ok = FALSE, error = substr(conditionMessage(error), 1L, 8192L)))
  encoded <- jsonlite::toJSON(response, auto_unbox = TRUE, null = "null", na = "null")
  if (nchar(encoded, type = "bytes") > 2097152L) {
    encoded <- jsonlite::toJSON(list(ok = FALSE, error = "preview result exceeds size limit"), auto_unbox = TRUE)
  }
  writeLines(encoded, args[[2L]], useBytes = TRUE)
}
main()
