use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
use tower_lsp::lsp_types::CompletionTextEdit;
use tower_lsp::lsp_types::Range;
use tower_lsp::lsp_types::TextEdit;
use tree_sitter::Point;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::completion_item::completion_item;
use crate::lsp::completions::sources::CompletionSource;
use crate::lsp::completions::types::CompletionData;
use crate::lsp::literate_math::command_at;

// A portable starter set, not a renderer-specific index of TeX packages.
const COMMANDS: &[&str] = &[
    // Greek letters
    "alpha",
    "beta",
    "gamma",
    "delta",
    "epsilon",
    "varepsilon",
    "zeta",
    "eta",
    "theta",
    "vartheta",
    "iota",
    "kappa",
    "lambda",
    "mu",
    "nu",
    "xi",
    "pi",
    "varpi",
    "rho",
    "varrho",
    "sigma",
    "varsigma",
    "tau",
    "upsilon",
    "phi",
    "varphi",
    "chi",
    "psi",
    "omega",
    "Gamma",
    "Delta",
    "Theta",
    "Lambda",
    "Xi",
    "Pi",
    "Sigma",
    "Upsilon",
    "Phi",
    "Psi",
    "Omega",
    // Relations, operators, arrows, and symbols
    "approx",
    "equiv",
    "ge",
    "geq",
    "le",
    "leq",
    "ne",
    "neq",
    "sim",
    "simeq",
    "propto",
    "in",
    "notin",
    "subset",
    "subseteq",
    "supset",
    "supseteq",
    "cup",
    "cap",
    "emptyset",
    "forall",
    "exists",
    "to",
    "gets",
    "leftarrow",
    "rightarrow",
    "leftrightarrow",
    "Leftarrow",
    "Rightarrow",
    "Leftrightarrow",
    "mapsto",
    "cdot",
    "times",
    "div",
    "pm",
    "mp",
    "infty",
    "partial",
    "nabla",
    "ldots",
    "cdots",
    "vert",
    "langle",
    "rangle",
    "sum",
    "prod",
    "int",
    "iint",
    "oint",
    "lim",
    "log",
    "ln",
    "exp",
    "min",
    "max",
    "sin",
    "cos",
    "tan",
    // Common structures and styles
    "frac",
    "sqrt",
    "binom",
    "left",
    "right",
    "hat",
    "widehat",
    "bar",
    "overline",
    "tilde",
    "widetilde",
    "vec",
    "dot",
    "ddot",
    "text",
    "mathrm",
    "mathbf",
    "mathit",
    "mathcal",
    "mathbb",
    "operatorname",
];

pub(super) struct MathSource;

impl CompletionSource for MathSource {
    fn name(&self) -> &'static str {
        "math"
    }

    fn provide_completions(
        &self,
        completion_context: &CompletionContext,
    ) -> anyhow::Result<Option<Vec<CompletionItem>>> {
        let context = completion_context.document_context;
        let Some(command) = command_at(context.document, context.point) else {
            // Trigger characters are shared across the server's filetypes.
            // An automatic backslash request outside math must stay silent.
            return Ok((context.trigger.as_deref() == Some("\\")).then(Vec::new));
        };

        let position = |column| {
            context
                .document
                .lsp_position_from_tree_sitter_point(Point::new(context.point.row, column))
        };
        let range = Range::new(position(command.range.start)?, position(command.range.end)?);
        let closing = if command.close_inline { "$" } else { "" };
        COMMANDS
            .iter()
            .filter(|name| name.starts_with(command.prefix))
            .map(|&name| {
                let mut item = completion_item(format!("\\{name}"), CompletionData::Unknown)?;
                item.kind = Some(CompletionItemKind::KEYWORD);
                item.filter_text = Some(String::from(name));
                item.text_edit = Some(CompletionTextEdit::Edit(TextEdit::new(
                    range,
                    format!("{name}{closing}"),
                )));
                Ok(item)
            })
            .collect::<anyhow::Result<_>>()
            .map(Some)
    }
}
