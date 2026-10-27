module FigureProvenanceMakieExt

using FigureProvenance
using Makie

FigureProvenance.write_figure(fig::Makie.FigureLike, path; kwargs...) = Makie.save(path, fig; kwargs...)

# Figure and FigureAxisPlot are immutable: tag their (mutable) scene instead
FigureProvenance._key(fig::Makie.Figure) = fig.scene
FigureProvenance._key(fig::Makie.FigureAxisPlot) = fig.figure.scene

end
