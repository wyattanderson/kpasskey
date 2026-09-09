"""Select the stock plugin from rules_foreign_cc's declared installation tree."""

def _pkinit_impl(ctx):
    output = ctx.actions.declare_file("pkinit.so")
    ctx.actions.run(
        executable = ctx.executable._tool,
        inputs = ctx.files.src,
        outputs = [output],
        arguments = [ctx.file.src.path, output.path],
        mnemonic = "SelectPKINIT",
    )
    return [DefaultInfo(files = depset([output]))]

pkinit_artifact = rule(
    implementation = _pkinit_impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "_tool": attr.label(default = "//build:select_artifact", executable = True, cfg = "exec"),
    },
)
