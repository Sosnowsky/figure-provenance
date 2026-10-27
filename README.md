# figure_provenance

Every figure folder gets a `provenance.json` that says, for each file in it, which code made it and why. Its readers are mostly AI assistants, asked months later to change a figure they have never seen.

```python
from figure_provenance import provenance, save

@provenance
def fig_tracks(ds, pixels, comp="vr"):
    """The maximum in space against the lag, one pixel a panel, with the fitted velocity."""
    fig, axes = plt.subplots(2, 3)
    ...
    return fig

save(fig_tracks(ds, [(4, 6), (5, 6)]), "figures/tracks.pdf", bbox_inches="tight")
```

`save` calls `fig.savefig` and writes the figure's entry, keyed by file name:

```json
{
  "about": "Written by the figure_provenance package ...",
  "figures": {
    "tracks.pdf": {
      "producer": "analysis/figures.py:fig_tracks",
      "call": "fig_tracks(ds=<Dataset {'y': 10, 'x': 9}>, pixels=[(4, 6), (5, 6)])",
      "called_from": "analysis/figures.py:120 (main)",
      "command": ".venv/bin/python -m analysis.figures",
      "cwd": ".",
      "date": "2026-09-25T15:12:03",
      "repo": "my_project",
      "remote": "git@github.com:someone/my_project.git",
      "commit": "3f2a9c1…",
      "uncommitted": ["analysis/figures.py"],
      "purpose": "The maximum in space against the lag, one pixel a panel, with the fitted velocity."
    }
  }
}
```

Paths are relative to the root of the producer's git repository, so an entry in a figures folder that lives in another repository (a manuscript on Overleaf) still leads back to the code.

## Conventions

- **The docstring is the purpose.** Keep it short, and say what the figure shows and why it is drawn that way. Update it whenever the figure changes: the manifest copies it on every save and cannot tell if it is stale. `save` warns when there is none.
- **Always save through `save`.** A figure written with `fig.savefig` directly has no entry.
- **A project's own `save` wrapper passes `stacklevel=2`.** Without `@provenance`, the entry names the code that called `save`, and the wrapper would otherwise name itself.
- **Commit, then regenerate.** A non-empty `uncommitted` means the code that ran was `commit` plus those changes, which cannot be recovered once they are reverted. The folder's own manifest and the figures it records are left out, since regenerating a committed figure folder rewrites them.
- **Arguments** appear as their `repr` when that is short plain data, and as their type (and shape) otherwise. `called_from` shows where they were built.

## Install

```bash
pip install git+https://github.com/Sosnowsky/figure-provenance.git

# or editable, from a clone, with the tests
git clone git@github.com:Sosnowsky/figure-provenance.git
pip install -e "figure-provenance[test]" && pytest figure-provenance
```

No dependencies. Python 3.10 or later, and git on the path for the repository fields.

## Julia

The `julia/` folder holds `FigureProvenance`, which writes the same `provenance.json`, so Python and Julia can save into one folder. The docstring goes above the macro, and `save` is called qualified, since Makie and Plots export their own:

```julia
using CairoMakie, FigureProvenance

"The maximum in space against the lag, one pixel a panel, with the fitted velocity."
@provenance function fig_tracks(ds, pixels; comp=:vr)
    fig = Figure()
    ...
    return fig
end

FigureProvenance.save(fig_tracks(ds, [(4, 6), (5, 6)]), "figures/tracks.pdf")
```

Makie and Plots figures are written by package extensions that load with those packages; add a `FigureProvenance.write_figure(fig, path)` method for any other kind. Differences from Python: `call` lists every argument, defaults included, and `command` is read from `/proc/self/cmdline` (on other systems, `julia` with the script and its arguments).

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path="../figure-provenance/julia")'  # from a project beside this repository
julia --project=julia -e 'using Pkg; Pkg.test()'                                   # the tests
```
