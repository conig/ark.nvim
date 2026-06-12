#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptState {
    PassThrough,
    TopLevel,
    Continuation,
    Browser,
    Debug,
    Recover,
}

impl PromptState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PassThrough => "pass-through",
            Self::TopLevel => "top-level",
            Self::Continuation => "continuation",
            Self::Browser => "browser",
            Self::Debug => "debug",
            Self::Recover => "recover",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptTransition {
    pub previous: PromptState,
    pub current: PromptState,
}

#[derive(Debug)]
pub struct PromptDetector {
    current: PromptState,
    line: String,
}

impl Default for PromptDetector {
    fn default() -> Self {
        Self::new()
    }
}

impl PromptDetector {
    pub fn new() -> Self {
        Self {
            current: PromptState::PassThrough,
            line: String::new(),
        }
    }

    #[cfg(test)]
    fn current(&self) -> PromptState {
        self.current
    }

    pub fn push_bytes(&mut self, bytes: &[u8]) -> Vec<PromptTransition> {
        let text = String::from_utf8_lossy(bytes);
        let mut transitions = Vec::new();

        for ch in strip_ansi(&text).chars() {
            match ch {
                '\r' | '\n' => self.line.clear(),
                '\u{08}' | '\u{7f}' => {
                    self.line.pop();
                },
                _ => self.line.push(ch),
            }

            if let Some(transition) = self.refresh_state() {
                transitions.push(transition);
            }
        }

        transitions
    }

    fn refresh_state(&mut self) -> Option<PromptTransition> {
        let next = classify_prompt_line(&self.line);
        if next == self.current {
            return None;
        }

        let transition = PromptTransition {
            previous: self.current,
            current: next,
        };
        self.current = next;
        Some(transition)
    }
}

fn classify_prompt_line(line: &str) -> PromptState {
    match line.trim_end() {
        ">" => PromptState::TopLevel,
        "+" => PromptState::Continuation,
        "Selection:" => PromptState::Recover,
        "debug>" => PromptState::Debug,
        trimmed if is_browser_prompt(trimmed) => PromptState::Browser,
        _ => PromptState::PassThrough,
    }
}

fn is_browser_prompt(line: &str) -> bool {
    let Some(inner) = line.strip_prefix("Browse[") else {
        return false;
    };
    let Some(level) = inner.strip_suffix("]>") else {
        return false;
    };

    !level.is_empty() && level.chars().all(|ch| ch.is_ascii_digit())
}

fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            out.push(ch);
            continue;
        }

        match chars.peek().copied() {
            Some('[') => {
                chars.next();
                for next in chars.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            },
            Some(']') => {
                chars.next();
                while let Some(next) = chars.next() {
                    if next == '\u{7}' {
                        break;
                    }
                    if next == '\u{1b}' && chars.peek().copied() == Some('\\') {
                        chars.next();
                        break;
                    }
                }
            },
            _ => {},
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_top_level_prompt() {
        let mut detector = PromptDetector::new();
        let transitions = detector.push_bytes(b"> ");

        assert_eq!(transitions, vec![PromptTransition {
            previous: PromptState::PassThrough,
            current: PromptState::TopLevel,
        }]);
        assert_eq!(detector.current(), PromptState::TopLevel);
    }

    #[test]
    fn detects_continuation_prompt() {
        let mut detector = PromptDetector::new();
        detector.push_bytes(b"> ");
        let transitions = detector.push_bytes(b"if (TRUE) {\r\n+ ");

        assert_eq!(
            transitions.last().unwrap().current,
            PromptState::Continuation
        );
        assert_eq!(detector.current(), PromptState::Continuation);
    }

    #[test]
    fn detects_browser_prompt() {
        let mut detector = PromptDetector::new();
        let transitions = detector.push_bytes(b"Called from: f()\r\nBrowse[2]> ");

        assert_eq!(transitions.last().unwrap().current, PromptState::Browser);
        assert_eq!(detector.current(), PromptState::Browser);
    }

    #[test]
    fn returns_to_pass_through_when_output_starts() {
        let mut detector = PromptDetector::new();
        detector.push_bytes(b"> ");
        let transitions = detector.push_bytes(b"cat('x')\r\nx\r\n");

        assert_eq!(transitions.first().unwrap(), &PromptTransition {
            previous: PromptState::TopLevel,
            current: PromptState::PassThrough,
        });
        assert_eq!(detector.current(), PromptState::PassThrough);
    }

    #[test]
    fn strips_ansi_before_classifying_prompt() {
        let mut detector = PromptDetector::new();
        let transitions = detector.push_bytes(b"\x1b[32m>\x1b[0m ");

        assert_eq!(transitions.last().unwrap().current, PromptState::TopLevel);
    }

    #[test]
    fn carriage_return_replaces_current_line() {
        let mut detector = PromptDetector::new();
        detector.push_bytes(b"progress 10%");
        let transitions = detector.push_bytes(b"\r> ");

        assert_eq!(transitions.last().unwrap().current, PromptState::TopLevel);
    }
}
