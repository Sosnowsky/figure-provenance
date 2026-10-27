using FigureProvenance
using JSON
using Test

mutable struct Fig
    values::Vector{Float64}
end
FigureProvenance.write_figure(fig::Fig, path) = write(path, string(fig.values))

"A line, for the tests."
@provenance function fig_line(values; scale=1.0, label=nothing)
    return Fig(vec(values) .* scale)
end

"Returns early, with a tuple."
@provenance function fig_pair(x)
    x > 0 && return (Fig([x]), :positive)
    return (Fig([0.0]), :other)
end

"Short form."
@provenance fig_short(x::Int) = Fig([x])

struct Wrapped  # immutable, like Makie's Figure
    inner::Fig
end
FigureProvenance._key(fig::Wrapped) = fig.inner
FigureProvenance.write_figure(::Wrapped, path) = write(path, "wrapped")

"Immutable, like a Makie Figure."
@provenance fig_wrapped() = Wrapped(Fig([1.0]))

"Saved without the macro."
draw_and_save(path) = FigureProvenance.save(Fig([1.0]), path)

wrapped_save(path) = FigureProvenance.save(Fig([1.0]), path; stacklevel=2)

read_manifest(folder) = JSON.parse(read(joinpath(folder, FigureProvenance.MANIFEST), String))

decorated(dir) = FigureProvenance.save(fig_line([1, 2, 3]; scale=2.0), joinpath(dir, "line.pdf"))

function undecorated(dir)
    draw_and_save(joinpath(dir, "a.png"))
    wrapped_save(joinpath(dir, "b.png"))
end

@testset "decorated" begin
    mktempdir() do dir
        decorated(dir)
        @test isfile(joinpath(dir, "line.pdf"))
        e = read_manifest(dir)["figures"]["line.pdf"]
        @test endswith(e["producer"], "runtests.jl:fig_line")
        @test e["call"] == "fig_line(values=[1, 2, 3], scale=2.0, label=nothing)"
        @test endswith(e["called_from"], "(decorated)")
        @test e["purpose"] == "A line, for the tests."
    end
end

@testset "early return, tuple, short form" begin
    mktempdir() do dir
        fig, sign = fig_pair(2.0)
        @test sign === :positive
        FigureProvenance.save(fig, joinpath(dir, "pair.png"))
        FigureProvenance.save(fig_short(3), joinpath(dir, "short.png"))
        figures = read_manifest(dir)["figures"]
        @test figures["pair.png"]["call"] == "fig_pair(x=2.0)"
        @test figures["pair.png"]["purpose"] == "Returns early, with a tuple."
        @test figures["short.png"]["call"] == "fig_short(x=3)"
        @test figures["short.png"]["purpose"] == "Short form."
    end
end

@testset "immutable figure" begin
    mktempdir() do dir
        FigureProvenance.save(fig_wrapped(), joinpath(dir, "w.png"))
        e = read_manifest(dir)["figures"]["w.png"]
        @test endswith(e["producer"], ":fig_wrapped")
        @test e["purpose"] == "Immutable, like a Makie Figure."
    end
end

@testset "arguments too large to print" begin
    mktempdir() do dir
        FigureProvenance.save(fig_line(zeros(3, 3); label="x"^200), joinpath(dir, "line.png"))
        call = read_manifest(dir)["figures"]["line.png"]["call"]
        @test startswith(call, "fig_line(values=<Matrix{Float64} (3, 3)>, scale=1.0, label=\"xxx")
        @test endswith(call, "...)")
        FigureProvenance.save(fig_line(collect(1.0:100.0)), joinpath(dir, "long.png"))
        call = read_manifest(dir)["figures"]["long.png"]["call"]
        @test startswith(call, "fig_line(values=<Vector{Float64} (100,)>,")
        @test FigureProvenance._describe([[1.0], [2.0]]) == "<Vector{Vector{Float64}} (2,)>"
        @test FigureProvenance._describe(0:0.5:2) == "0.0:0.5:2.0"
    end
end

@testset "entries accumulate" begin
    mktempdir() do dir
        FigureProvenance.save(fig_line([1]), joinpath(dir, "b.png"))
        FigureProvenance.save(fig_line([2]), joinpath(dir, "a.png"))
        FigureProvenance.save(fig_line([3]), joinpath(dir, "b.png"))
        data = read_manifest(dir)
        @test data["about"] == FigureProvenance.ABOUT
        @test collect(keys(data["figures"])) == ["a.png", "b.png"]
        @test data["figures"]["b.png"]["call"] == "fig_line(values=[3], scale=1.0, label=nothing)"
    end
end

@testset "keeps entries written by Python" begin
    # an entry as Python's json.dump(indent=2) writes it
    python = """
        "py.pdf": {
          "producer": "analysis/figures.py:fig_tracks",
          "call": "fig_tracks(pixels=[(4, 6)])",
          "cwd": ".",
          "uncommitted": [],
          "purpose": "From Python, é."
        }"""
    mktempdir() do dir
        manifest = joinpath(dir, FigureProvenance.MANIFEST)
        indented = "    " * replace(python, "\n" => "\n    ")
        write(manifest, "{\n  \"about\": \"old\",\n  \"figures\": {\n$indented\n  }\n}\n")
        FigureProvenance.save(fig_line([1]), joinpath(dir, "a.png"))
        text = read(manifest, String)
        @test occursin(indented, text)
        @test collect(keys(JSON.parse(text)["figures"])) == ["a.png", "py.pdf"]
    end
end

@testset "undecorated" begin
    mktempdir() do dir
        @test_logs (:warn, r"undecorated has no docstring") undecorated(dir)
        figures = read_manifest(dir)["figures"]
        @test endswith(figures["a.png"]["producer"], ":draw_and_save")
        @test figures["a.png"]["purpose"] == "Saved without the macro."
        @test figures["a.png"]["call"] === nothing
        @test endswith(figures["b.png"]["producer"], ":undecorated")
    end
end

@testset "warns without docstring" begin
    mktempdir() do dir
        @test_logs (:warn, r"no docstring") FigureProvenance.save(Fig([1.0]), joinpath(dir, "a.png"))
    end
end

@testset "git" begin
    mktempdir() do tmp
        repo = joinpath(tmp, "repo")
        mkdir(repo)
        write(joinpath(repo, "mod.jl"), """
            using FigureProvenance
            mutable struct G end
            FigureProvenance.write_figure(::G, path) = write(path, "g")

            "In a repository."
            @provenance fig() = G()
            """)
        write(joinpath(repo, "other.txt"), "a\n")
        git(args...) = run(pipeline(`git -C $repo -c user.name=t -c user.email=t@t -c init.defaultBranch=main $args`; stdout=devnull))
        git("init")
        git("add", ".")
        git("commit", "-m", "first")
        write(joinpath(repo, "other.txt"), "b\n")
        mod = Module(:InRepo)
        Base.include(mod, joinpath(repo, "mod.jl"))

        # in the world where mod.jl's definitions exist
        Base.invokelatest(() -> FigureProvenance.save(mod.fig(), joinpath(tmp, "out", "fig.png")))
        e = read_manifest(joinpath(tmp, "out"))["figures"]["fig.png"]
        @test e["producer"] == "mod.jl:fig"
        @test e["purpose"] == "In a repository."
        @test e["repo"] == "repo"
        @test e["commit"] == readchomp(`git -C $repo rev-parse HEAD`)
        @test e["uncommitted"] == ["other.txt"]
        @test e["remote"] === nothing
    end
end

@testset "outputs are not uncommitted" begin
    # regenerating a committed figure folder: its figures and manifest are outputs, not code
    mktempdir() do tmp
        repo = joinpath(tmp, "repo")
        mkdir(repo)
        write(joinpath(repo, "mod.jl"), """
            using FigureProvenance
            mutable struct H
                s::String
            end
            FigureProvenance.write_figure(h::H, path) = write(path, h.s)

            "In a repository."
            @provenance fig(s) = H(s)
            """)
        write(joinpath(repo, "other.txt"), "a\n")
        git(args...) = run(pipeline(`git -C $repo -c user.name=t -c user.email=t@t -c init.defaultBranch=main $args`; stdout=devnull))
        git("init")
        mod = Module(:Outputs)
        Base.include(mod, joinpath(repo, "mod.jl"))
        figs = joinpath(repo, "figs")
        save_both(s) = Base.invokelatest() do
            FigureProvenance.save(mod.fig(s), joinpath(figs, "a.png"))
            FigureProvenance.save(mod.fig(s), joinpath(figs, "b.png"))
        end
        save_both("1")
        git("add", ".")
        git("commit", "-m", "first")
        write(joinpath(repo, "other.txt"), "b\n")
        save_both("2")  # the figures themselves change
        figures = read_manifest(figs)["figures"]
        @test figures["a.png"]["uncommitted"] == ["other.txt"]
        @test figures["b.png"]["uncommitted"] == ["other.txt"]
    end
end
