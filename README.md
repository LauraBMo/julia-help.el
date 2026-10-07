# julia-help.el

Julia documentation in a buffer of its own — the Emacs half of
[EmacsVterm.jl](https://github.com/wentasah/EmacsVterm.jl).

`@doc sin` in a Julia REPL running under `vterm` no longer drops rendered HTML
into a plain `*julia-doc*` buffer. It opens a buffer named after the symbol, in
a mode with its own keys, holding the binding, the defining module, the
signature, a **Methods** table whose rows open the source, and docstring
cross-references that are actual buttons.

## Why the rendering half lives here

The docs arrive as HTML, and it is not EmacsVterm.jl that renders them badly.
EmacsVterm.jl turns the Julia `Markdown.MD` into HTML and base64s it down a
vterm escape; `julia-repl--show` — which lives in *julia-repl.el*, not in
EmacsVterm.jl — is what drops it into a plain buffer with `shr-render-region`
and `view-mode`. So the rendering half is ours to change, and the Julia half
need only start sending more than the HTML.

The buffer is per symbol, rebuilt from a JSON payload carrying the docstring's
HTML plus the metadata Julia already attaches to it. Two things come out of that
beyond nicer text.

**Cross-references work.** A Julia docstring is full of `[`foo`](@ref)` links,
and `Markdown.html` writes every one of them as `href="@ref"` with the symbol in
the link *text* — which `shr` hands to `browse-url` as the literal string
`"@ref"`. They are the most useful links a docstring has and the only ones that
go nowhere. Here they become buttons that ask the REPL for that symbol's
documentation, so following one behaves like `M-x helpful-*` on an elisp symbol.

**Every method gets a source line.** The *Methods* rows carry the file and line
Julia records for that method, and open it. Stdlib methods need care: the path
they carry is baked on the machine Julia was built on (`/cache/build/...`), so
the [Julia side](#the-julia-half) rebases it under `Sys.STDLIB` before sending.
A row whose file still cannot be found is left as plain text, rather than a
button that opens nothing.

## Requirements

- Emacs 29.1 or later
- [`vterm`](https://github.com/akermu/emacs-libvterm) — the transport
- [`julia-repl`](https://github.com/tpapp/julia-repl) — the caller: its
  `julia-repl--show` hands `documentation` as `application/json` here, and
  renders every other kind itself, images included.

  It has to be a version that defines `julia-repl-show-mime-types`, the variable
  this package adds its MIME type to when it loads. The JSON support behind that
  is not released upstream yet — it is on
  [`json-documentation`](https://github.com/LauraBMo/julia-repl/tree/json-documentation),
  PR pending — so an older `julia-repl` makes loading this file signal
  `void-variable julia-repl-show-mime-types`.
- [EmacsVterm.jl](https://github.com/wentasah/EmacsVterm.jl) loaded in the Julia
  REPL

## Install

```elisp
(add-to-list 'load-path "/path/to/julia-help.el")
(require 'julia-help)
```

With straight or Doom, declare it as a package instead:

```elisp
(package! julia-help :recipe (:host github :repo "LauraBMo/julia-help.el"))
```

Nothing needs enabling. `julia-repl--show` calls in; there is no vterm command
to register.

## Keys

| Key | |
|---|---|
| `RET` | follow the cross-reference at point |
| `TAB`, `n` | next link |
| `S-TAB`, `p` | previous link |
| `h` | back to the documentation this was reached from |
| `l` | on to the documentation reached from this |
| `gr` | redraw the buffer from its payload |
| `q` | quit the window (`special-mode`) |

Under Evil these buffers open in normal state, where a minor mode's map does not
by itself outrank it. Give the mode map precedence, or the keys above silently do
nothing:

```elisp
(with-eval-after-load 'evil
  (evil-make-overriding-map julia-help-mode-map 'normal))
```

TAB is worth a note of its own.  It arrives as two different key sequences — a
graphical frame sends the vector `[tab]`, a terminal and `C-i` send the string
`"\t"` — and the mode map binds both.  So TAB here keeps working even if your own
config binds `[tab]` globally in normal state; the mode map takes it back.  A
binding written as only `(kbd "TAB")` would not: `key-binding` would report it
while a real keypress ran the other binding.

Where a *new* doc buffer appears is deliberately not this package's business: it
asks for a plain `pop-to-buffer` and leaves placement to the display policy. If
you want a followed link to land in the window you were reading in rather than
splitting the frame, that is a `display-buffer-alist` rule keyed on
`julia-help-mode`:

```elisp
(add-to-list 'display-buffer-alist
             '((major-mode . julia-help-mode)
               (display-buffer-reuse-window display-buffer-same-window)))
```

## The wire

Commands travel as vterm escape sequences (`ESC ]51;E...ESC \`), and `vterm--eval`
splits the arguments with `split-string-and-unquote`, which *unquotes* `\"` and
`\\`. A raw JSON argument would be mangled in transit, so the payload stays
base64 the whole way and is decoded here. Measured at the point `vterm--eval`
runs, the current buffer is the vterm buffer — which is how a doc buffer learns
which REPL to send a cross-reference back to.

The command name is part of that wire, and it is a *string*: EmacsVterm.jl's
`SHOW_COMMAND` and this package's `vterm-eval-cmds` entry have to agree, and both
are `julia-help-show`.  Released EmacsVterm.jl 0.3.0 sends `julia-repl--show`
instead, which this package does not intercept — against it, docstrings render
the old way, and the buffer is `*julia-doc*` rather than `*julia-help: SYMBOL*`.

## Running the tests

```sh
emacs -Q --batch -L . -l julia-help-test.el
```

Exit code is the verdict. The suite runs itself when loaded in batch, so a load
that tested nothing cannot be read as a pass. It needs no Julia and disturbs no
REPL: the payload is a fixture and `vterm-send-string` is replaced.

## The Julia half

The matching `EmacsVterm.jl` changes send the JSON payload instead of bare HTML,
and point `SHOW_COMMAND` at `julia-help-show`. The Julia `Markdown.MD` for a
docstring carries the metadata already — `md.meta[:binding]`, `[:typesig]`,
`[:results]`, and per result `:module`, `:path`, `:linenumber` — and the old
code computed all of it and threw it away by sending `Markdown.html(md)` alone.
Sending it too is what this buffer is drawn from, and it costs one JSON object
per docstring.

Two details for whoever touches that half:

- A field with nothing in it must be sent as `null`, not `""`. An empty string
  is *true* in elisp, so the receiver treats `""` as absent as well — a
  half-updated Julia must render identically to an up-to-date one.
- `?help` goes through `REPL.helpmode` and displays an `MD` of its own making,
  so the metadata is genuinely absent there rather than empty. That path renders
  as the plain `*julia-help*` buffer, with the docstring and no header.

## Licence

MIT. See [LICENSE](LICENSE).
