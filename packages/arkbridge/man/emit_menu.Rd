\name{emit_menu}
\alias{emit_menu}
\title{Inspect an expression for Ark completion}
\usage{
emit_menu(expr, options = list())
}
\arguments{
  \item{expr}{A length-one character expression evaluated in the requested environment.}
  \item{options}{A list of inspection and session options.}
}
\value{
A JSON string containing object metadata and members, or a structured Ark error payload.
}
\description{
Evaluates an R expression and serializes the object metadata and member information used by Ark runtime completion.
}
