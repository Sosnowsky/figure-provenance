module FigureProvenancePlotsExt

using FigureProvenance
using Plots

FigureProvenance.write_figure(fig::Plots.Plot, path) = Plots.savefig(fig, path)

end
