
LSP TODO
========

- [] How should strings and quoted symbols be presented in the completion list?
     Do we want to display their quoted representation, or display the "raw" representation and then
     quote them appropriately on insertion?

- [] Rather than testing `node.kind()`, can we check the `node.kind_id()`? Are we able to read these
     from the language's NODE_TYPES member? Does rust have some clever way of parsing a string of
     .json at compile time so we have an easy-to-use data structure to work with?
