"""
Record, beside each saved figure, what made it: for whoever -- often an AI -- has to change it later.

`FigureProvenance.save(fig, path)` writes the figure, and its entry in the `provenance.json` of the
same folder: the function that drew it, its arguments, the line that called it, the command that
ran, the git commit of the code with the files that differed from it, the date, and the function's
docstring as the figure's purpose. The function is known when it is defined with `@provenance`;
without that, the entry names the code that called `save`.

    using FigureProvenance

    "What the figure shows, and why it is drawn the way it is."
    @provenance function fig_tracks(ds, pixels)
        fig = Figure()
        ...
        return fig
    end

    FigureProvenance.save(fig_tracks(ds, pixels), "figures/tracks.pdf")

The manifest is the one the Python package `figure_provenance` writes, so both can save into one
folder.
"""
module FigureProvenance

using Dates
using JSON

export @provenance

const MANIFEST = "provenance.json"
const ABOUT = string(
    "Written by the figure_provenance package (https://github.com/Sosnowsky/figure-provenance) each time ",
    "a figure in this folder is saved, one entry per ",
    "file. 'producer' is the function that drew it, a path inside the git repository 'repo' (remote ",
    "'remote') at 'commit'; 'uncommitted' lists the files that differed from that commit when it ran, ",
    "other than this file and the figures it records. ",
    "'call' gives its arguments, 'called_from' the line that called it, 'command' what was run, from ",
    "'cwd'. 'purpose' is the producer's docstring. To change a figure, edit the producer and its ",
    "docstring and rerun it: an edit to the file itself is lost on the next run.",
)

# figure => what drew it, set by the functions defined with @provenance
const _MADE = WeakKeyDict{Any,Any}()

# The mutable object that stands for `fig` in _MADE: an extension adds a method
# for an immutable figure type, such as Makie's Figure, returning its scene.
_key(fig) = fig

"""
    @provenance function f(args...; kwargs...) ... end

Define a function returning a figure, or a tuple starting with one, so `save` knows what drew it.
The docstring written above `@provenance` is the figure's purpose.
"""
macro provenance(def)
    call = def isa Expr && def.head in (:function, :(=)) ? _signature(def.args[1]) : nothing
    call === nothing && throw(ArgumentError("@provenance expects a function definition"))
    name = call.args[1]
    name isa Symbol || throw(ArgumentError("@provenance needs a plain function name, not $name"))
    params = call.args[2:end]
    kw = !isempty(params) && Meta.isexpr(params[1], :parameters) ? popfirst!(params).args : []
    names = filter(!isnothing, map(_argname, [params; kw]))
    args = Expr(:tuple, (:($(string(n)) => $n) for n in names)...)
    file = abspath(string(__source__.file))
    result = gensym(:result)
    body = quote
        $result = (() -> $(def.args[2]))()
        $_tag($result, $(QuoteNode(name)), $__module__, $file, $args)
        $result
    end
    return esc(:(Base.@__doc__ $(Expr(def.head, def.args[1], body))))
end

_signature(ex) =
    Meta.isexpr(ex, :call) ? ex :
    Meta.isexpr(ex, :where) || (Meta.isexpr(ex, :(::)) && length(ex.args) == 2) ? _signature(ex.args[1]) :
    nothing

_argname(a::Symbol) = a
function _argname(a::Expr)
    a.head === :(::) && return length(a.args) == 2 ? _argname(a.args[1]) : nothing
    a.head in (:kw, :(=), :...) && return _argname(a.args[1])
    return nothing  # a destructured argument
end
_argname(_) = nothing

@noinline function _tag(result, name::Symbol, mod::Module, file::String, args)
    key = _key(result isa Tuple && !isempty(result) ? first(result) : result)
    ismutable(key) || return
    call = string(name, "(", join(("$k=$(_describe(v))" for (k, v) in args), ", "), ")")
    _MADE[key] = (; file, name=string(name), doc=_docstring(mod, name), call, caller=_caller(name))
    return
end

"""
    FigureProvenance.save(fig, path; stacklevel=1, kwargs...)

`write_figure(fig, path; kwargs...)`, then the figure's entry in the `provenance.json` beside it.

Without `@provenance` on the function that drew `fig`, the entry names the code that called `save`;
a project's own wrapper around `save` passes `stacklevel=2`, so that it names the wrapper's caller
rather than the wrapper.
"""
@noinline function save(fig, path::AbstractString; stacklevel::Integer=1, kwargs...)
    mkpath(dirname(abspath(path)))
    write_figure(fig, path; kwargs...)
    key = _key(fig)
    made = ismutable(key) ? get(_MADE, key, nothing) : nothing
    if made === nothing
        frames = _frames()
        frame = frames[stacklevel]
        # an inlined frame has no module: take that of the function it was inlined into
        mod = something(map(parentmodule, frames[stacklevel:end])..., Main)
        name = frame.func === Symbol("top-level scope") ? nothing : _demangle(frame.func)
        doc = name === nothing ? nothing : _docstring(mod, Symbol(name))
        made = (; file=string(frame.file), name, doc, call=nothing, caller=frame)
    end
    entry = _entry(made, path)
    if entry["purpose"] === nothing
        @warn "$(entry["producer"]) has no docstring: $MANIFEST will not say what $(basename(path)) is for"
    end
    _record(path, entry)
    return path
end

"""
    FigureProvenance.write_figure(fig, path; kwargs...)

Write `fig` to `path`. Methods for Makie and Plots figures load with those packages; add one for
any other kind of figure.
"""
write_figure(fig, path; kwargs...) = throw(ArgumentError(
    "no write_figure method for a $(typeof(fig)): load Makie (or CairoMakie, GLMakie) or Plots first"))

"""The docstring of `mod.name`, or nothing."""
function _docstring(mod::Module, name::Symbol)
    meta = Base.Docs.meta(mod)
    binding = Base.Docs.Binding(mod, name)
    haskey(meta, binding) || return nothing
    texts = [strip(join(string.(d.text))) for d in values(meta[binding].docs)]
    filter!(!isempty, texts)
    return isempty(texts) ? nothing : join(texts, "\n\n")
end

# `#f#3` is the body of a function `f` with keyword arguments; `#5` is a closure, with no name
function _demangle(func::Symbol)
    s = string(func)
    s = startswith(s, '#') ? split(s, '#')[2] : s
    return Base.isidentifier(s) ? s : nothing
end

# Base (relative "./" paths) and Core frames: `map`, `include`, `invokelatest`
_inbase(frame) = startswith(string(frame.file), "./") || parentmodule(frame) in (Base, Core)

"""The stack outside this package and Base, from the caller of the function calling it."""
_frames() = filter(stacktrace()) do frame
    # inlined frames have no module, but still this file
    !(parentmodule(frame) === FigureProvenance || string(frame.file) == _SOURCE ||
      frame.func === :kwcall || _inbase(frame))
end
const _SOURCE = @__FILE__

"""The frame that called the function `name`."""
function _caller(name::Symbol)
    own(frame) = frame.func === name || frame.func === :kwcall || startswith(string(frame.func), "#$name#")
    frames = stacktrace()
    i = findfirst(own, frames)
    i === nothing && return nothing
    j = findnext(frame -> !own(frame) && !_inbase(frame), frames, i)
    return j === nothing ? nothing : frames[j]
end

function _entry(made, path)
    root = _root(made.file)
    producer = _rel(made.file, root) * (made.name === nothing ? "" : ":$(made.name)")
    caller = made.caller
    entry = JSON.Object{String,Any}(
        "producer" => producer,
        "call" => made.call,
        "called_from" => caller === nothing ? nothing :
                         "$(_rel(string(caller.file), root)):$(caller.line) ($(caller.func))",
        "command" => _command(),
        "cwd" => _rel(pwd(), root),
        "date" => Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"),
    )
    if root !== nothing
        status = something(_git(root, "status", "--porcelain", "--untracked-files=no"), "")
        outputs = _outputs(path, root)
        uncommitted = [line[4:end] for line in split(status, '\n') if !isempty(strip(line)) && line[4:end] ∉ outputs]
        rel = _rel(made.file, root)
        if _git(root, "ls-files", "--error-unmatch", "--", rel) === nothing
            push!(uncommitted, "$rel (untracked)")
        end
        remote = strip(something(_git(root, "remote", "get-url", "origin"), ""))
        commit = strip(something(_git(root, "rev-parse", "HEAD"), ""))
        entry["repo"] = basename(root)
        entry["remote"] = isempty(remote) ? nothing : remote
        entry["commit"] = isempty(commit) ? nothing : commit
        entry["uncommitted"] = uncommitted
    end
    entry["purpose"] = made.doc
    return entry
end

"""The manifest beside `path` and the figures it records, as git names them: outputs, not code."""
function _outputs(path, root)
    folder = dirname(abspath(path))
    names = Set([MANIFEST, basename(path)])
    manifest = joinpath(folder, MANIFEST)
    if isfile(manifest)
        try
            union!(names, keys(get(JSON.parse(read(manifest, String)), "figures", Dict())))
        catch  # not valid JSON: _record says so
        end
    end
    return Set(_rel(joinpath(folder, name), root) for name in names)
end

"""The command line that started this process, as it would be typed."""
function _command()
    argv = try
        split(read("/proc/self/cmdline", String), '\0'; keepempty=false)
    catch  # not Linux
        String[]
    end
    if isempty(argv)
        argv = filter(!isempty, ["julia", PROGRAM_FILE, ARGS...])
    else
        argv[1] = basename(argv[1])  # the binary inside juliaup's folder: `julia` is what is typed
    end
    return Base.shell_escape(argv...)
end

function _record(path, entry)
    manifest = joinpath(dirname(abspath(path)), MANIFEST)
    open(manifest, "a+") do io
        Sys.iswindows() || ccall(:flock, Cint, (Cint, Cint), fd(io), 2)  # LOCK_EX: two processes saving into one folder: neither entry lost
        seekstart(io)
        text = read(io, String)
        data = try
            isempty(strip(text)) ? JSON.Object{String,Any}() : JSON.parse(text)
        catch
            throw(ArgumentError("$manifest is not valid JSON: fix or delete it"))
        end
        figures = get(data, "figures", JSON.Object{String,Any}())
        figures[basename(path)] = entry
        sorted = JSON.Object{String,Any}(k => figures[k] for k in sort!(collect(keys(figures))))
        seekstart(io)
        truncate(io, 0)
        JSON.json(io, JSON.Object{String,Any}("about" => ABOUT, "figures" => sorted); pretty=2)
        write(io, '\n')
    end
end

"""An argument as the manifest gives it: its `repr` when that is short and plain data, else its type."""
function _describe(value; limit=120)
    if value isa AbstractArray && !(value isa AbstractRange)
        # a flat vector of plain values, short enough to print whole: else its type and size
        flat = ndims(value) == 1 && length(value) <= limit &&
               all(x -> _plain(x) && !(x isa AbstractArray), value)
        text = flat ? repr(value) : ""
        flat && length(text) <= limit && return text
        kind = value isa Array ? string(typeof(value)) : string(nameof(typeof(value)))
        return "<$kind $(size(value))>"
    end
    _plain(value) || return "<$(nameof(typeof(value)))>"
    text = repr(value)
    return length(text) <= limit ? text : first(text, limit - 3) * "..."
end

_plain(_) = false
_plain(::Union{Nothing,Missing,AbstractString,Number,Symbol,Char,Enum}) = true
_plain(::AbstractRange) = true
_plain(value::Union{Tuple,NamedTuple,AbstractVector,AbstractSet}) = all(_plain, value)
_plain(value::AbstractDict) = all(((k, v),) -> _plain(k) && _plain(v), value)

function _git(root, args...)
    out = IOBuffer()
    try
        success(pipeline(`git -C $root $args`; stdout=out, stderr=devnull)) || return nothing
    catch  # no git
        return nothing
    end
    return String(take!(out))
end

"""The root of the git repository holding `file`, or nothing."""
function _root(file)
    isfile(file) || return nothing  # the REPL
    root = _git(dirname(realpath(file)), "rev-parse", "--show-toplevel")
    return root === nothing ? nothing : realpath(strip(root))
end

function _rel(path, root)
    path = ispath(path) ? realpath(path) : abspath(path)
    if root !== nothing && (path == root || startswith(path, root * "/"))
        return relpath(path, root)
    end
    return path
end

end
