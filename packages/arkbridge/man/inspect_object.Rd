\name{inspect_object}
\alias{inspect_object}
\title{Inspect an R object for Ark}
\usage{
inspect_object(obj, options = list())
}
\arguments{
  \item{obj}{An R object to inspect.}
  \item{options}{A list controlling the request profile, member filtering, enrichment, and output limits.}
}
\value{
A list with \code{object_meta} and \code{members} entries.
}
\description{
Builds the normalized object and member metadata used by Ark runtime features.
}
