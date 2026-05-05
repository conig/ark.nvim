use serde_json::json;
use tower_lsp::lsp_types;
use url::Url;

use crate::lsp::capabilities::Capabilities;
use crate::lsp::code_action::CodeActions;
use crate::lsp::document::Document;
use crate::lsp::indexer;
use crate::lsp::state::WorldState;
use crate::lsp::traits::node::NodeExt;
use crate::treesitter::NodeTypeExt;

pub(crate) fn target_actions(
    actions: &mut CodeActions,
    uri: &Url,
    document: &Document,
    range: tree_sitter::Range,
    capabilities: &Capabilities,
    state: &WorldState,
) -> Option<()> {
    if !capabilities.code_action_literal_support() {
        return None;
    }

    let name = target_name_at_range(document, range)?;
    if !is_static_target(name.as_str(), uri, document, state) {
        return None;
    }

    actions.add_action(target_command_action(
        format!("Ark: Build target `{name}`"),
        "make",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        format!("Ark: Build downstream of `{name}`"),
        "makeDownstream",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        format!("Ark: Load target `{name}`"),
        "load",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        format!("Ark: Invalidate target `{name}`"),
        "invalidate",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        format!("Ark: Show target status `{name}`"),
        "status",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        format!("Ark: Show object metadata for `{name}`"),
        "objectMeta",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        format!("Ark: Open target log for `{name}`"),
        "log",
        Some(name.as_str()),
    ));
    actions.add_action(target_command_action(
        String::from("Ark: Show target graph"),
        "graph",
        None,
    ))
}

fn target_command_action(title: String, action: &str, name: Option<&str>) -> lsp_types::CodeAction {
    lsp_types::CodeAction {
        title: title.clone(),
        kind: Some(lsp_types::CodeActionKind::QUICKFIX),
        diagnostics: None,
        edit: None,
        command: Some(lsp_types::Command {
            title,
            command: String::from("ark.targetAction"),
            arguments: Some(vec![json!({
                "action": action,
                "name": name,
            })]),
        }),
        is_preferred: None,
        disabled: None,
        data: None,
    }
}

fn target_name_at_range(document: &Document, range: tree_sitter::Range) -> Option<String> {
    let root = document.ast.root_node();
    let mut point = range.start_point;
    let mut node = root.descendant_for_point_range(point, point)?;

    if !node.is_identifier_or_string() && point.column > 0 {
        point.column -= 1;
        node = root.descendant_for_point_range(point, point)?;
    }

    let node = node
        .ancestors()
        .find(|node| node.is_identifier_or_string())?;

    node.get_identifier_or_string_text(document.contents.as_str())
        .ok()
        .map(str::to_string)
}

fn is_static_target(symbol: &str, uri: &Url, document: &Document, state: &WorldState) -> bool {
    if indexer::find_in_document(symbol, uri, document)
        .is_some_and(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
    {
        return true;
    }

    for (open_uri, open_document) in &state.documents {
        if indexer::find_in_document(symbol, open_uri, open_document)
            .is_some_and(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
        {
            return true;
        }
    }

    indexer::find(symbol)
        .is_some_and(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
}

#[cfg(test)]
mod tests {
    use tower_lsp::lsp_types::CodeActionOrCommand;
    use tree_sitter::Point;
    use tree_sitter::Range;
    use url::Url;

    use crate::fixtures::point_and_offset_from_cursor;
    use crate::lsp::capabilities::Capabilities;
    use crate::lsp::code_action::targets::target_actions;
    use crate::lsp::code_action::CodeActions;
    use crate::lsp::document::Document;
    use crate::lsp::state::WorldState;

    fn point_range(point: Point, byte: usize) -> Range {
        Range {
            start_byte: byte,
            end_byte: byte,
            start_point: point,
            end_point: point,
        }
    }

    fn target_actions_at_cursor(text: &str) -> Vec<tower_lsp::lsp_types::CodeAction> {
        let mut actions = CodeActions::new();
        let uri = Url::parse("file:///project/_targets.R").unwrap();
        let capabilities = Capabilities::default().with_code_action_literal_support(true);
        let state = WorldState::default();
        let (text, point, offset) = point_and_offset_from_cursor(text, b'@');
        let document = Document::new(&text, None);

        target_actions(
            &mut actions,
            &uri,
            &document,
            point_range(point, offset),
            &capabilities,
            &state,
        );

        actions
            .into_response()
            .into_iter()
            .map(|action| match action {
                CodeActionOrCommand::CodeAction(action) => action,
                CodeActionOrCommand::Command(_) => panic!("unexpected command response"),
            })
            .collect()
    }

    #[test]
    fn test_target_code_actions_on_target_definition() {
        let actions = target_actions_at_cursor(
            r#"
list(
  tar_target(clean_@data, raw_data + 1)
)
"#,
        );

        let titles: Vec<_> = actions.iter().map(|action| action.title.as_str()).collect();
        assert_eq!(titles, vec![
            "Ark: Build target `clean_data`",
            "Ark: Build downstream of `clean_data`",
            "Ark: Load target `clean_data`",
            "Ark: Invalidate target `clean_data`",
            "Ark: Show target status `clean_data`",
            "Ark: Show object metadata for `clean_data`",
            "Ark: Open target log for `clean_data`",
            "Ark: Show target graph",
        ]);

        let command = actions[0].command.as_ref().unwrap();
        assert_eq!(command.command, "ark.targetAction");
        assert_eq!(
            command.arguments.as_ref().unwrap()[0]["action"].as_str(),
            Some("make")
        );
        assert_eq!(
            command.arguments.as_ref().unwrap()[0]["name"].as_str(),
            Some("clean_data")
        );
    }

    #[test]
    fn test_target_code_actions_on_string_reference() {
        let actions = target_actions_at_cursor(
            r#"
list(
  tar_target(clean_data, raw_data + 1),
  tar_target(report, tar_read("clean_@data"))
)
"#,
        );

        assert_eq!(actions.len(), 8);
        assert_eq!(actions[4].title, "Ark: Show target status `clean_data`");
    }

    #[test]
    fn test_no_target_code_actions_for_unknown_symbol() {
        let actions = target_actions_at_cursor(
            r#"
list(
  tar_target(clean_data, raw_data + 1),
  tar_target(report, tar_read("missing_@target"))
)
"#,
        );

        assert!(actions.is_empty());
    }
}
