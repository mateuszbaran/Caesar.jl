# using Distributed
# addprocs(5)

using Caesar, RoME, Profile
using RoMEPlotting, Gadfly, KernelDensityEstimatePlotting
using KernelDensityEstimate
using IncrementalInference
using DocStringExtensions
using DelimitedFiles
# using TransformUtils

include(joinpath(@__DIR__,"slamUtils.jl"))

function main(windowstart::Int, windowlen::Int,saswindow::Int,sasstart::Int)

poses = [Symbol("x$i") for i in 1:windowlen]
alldataframes = collect(windowstart:windowstart+windowlen);
sasdataframes = collect(windowstart+sasstart:1:(windowstart+sasstart+saswindow-1))
sasposes = [Symbol("x$i") for i in sasstart:sasstart+saswindow-1]

dataDir = joinpath("/media","data1","data","kayaks","20_gps_pos") #liljon data
cfgFile = joinpath("/media","data1","data","kayaks","SAS2D.yaml");
chirpFile = joinpath("/media","data1","data","kayaks","chirp250.txt");

# dataDir = joinpath(ENV["HOME"],"data","kayaks","20_gps_pos") #local copy
# cfgFile = joinpath(ENV["HOME"],"data","sas","SAS2D.yaml");
# chirpFile = joinpath(ENV["HOME"],"data","sas","chirp250.txt");
cfgd=loadConfigFile(cfgFile)

fg = initfg();
beacon = :l1
addVariable!(fg, beacon, Point2 )

posData = importdata_nav(alldataframes, datadir=dataDir);
navchecked, errorind = sanitycheck_nav(posData)
dposData = deepcopy(posData)
cumulativeDrift!(dposData,[0.0;0],[0.1,0.1])

waveformData = importdata_waveforms(sasdataframes,2, datadir=dataDir);
tcurrent = 1_000_000

for sym in poses
  addVariable!(fg, sym, DynPoint2(ut=tcurrent))
  tcurrent += 1_000_000
end

priors = [1]
#Priors
for i in priors
    xdotp = posData[i+1,1] - posData[i,1];
    ydotp = posData[i+1,2] - posData[i,2];
    dpμ = [posData[i,1];posData[i,2];xdotp;ydotp];
    dpσ = Matrix(Diagonal([0.1;0.1;0.1;0.1].^2))
    pp = DynPoint2VelocityPrior(MvNormal(dpμ,dpσ))
    addFactor!(fg, [poses[i];], pp, autoinit=false)
end

vps = 1:windowlen-1
for i in vps
    xdotp = dposData[i+1,1] - dposData[i,1];
    ydotp = dposData[i+1,2] - dposData[i,2];
    dpμ = [xdotp;ydotp;0;0];
    dpσ = Matrix(Diagonal([0.1;0.1;0.1;0.1].^2))
    vp = VelPoint2VelPoint2(MvNormal(dpμ,dpσ))
    addFactor!(fg, [poses[i];poses[i+1]], vp, autoinit=false)
    # IncrementalInference.doautoinit!(fg,[getVariable(fg,poses[i])])
end

# IncrementalInference.doautoinit!(fg,[getVariable(fg,poses[5])])
sas2d = prepareSAS2DFactor(saswindow, waveformData, rangemodel=:Correlator,
                           cfgd=cfgd, chirpFile=chirpFile)
addFactor!(fg, [beacon;sasposes], sas2d, autoinit=false)

# visualization tools for debugging
writeGraphPdf(fg,viewerapp="", engine="neato", filepath="/media/data1/data/kayaks/testfg.pdf")
# wipeBuildNewTree!(fg, drawpdf=true, show=false)

getSolverParams(fg).drawtree = true
#getSolverParams(fg).showtree = true

## solve the factor graph
tree, smt, hist = solveTree!(fg, recordcliqs=[:x3; :l1])

drawTree(tree, filepath="/media/data1/data/kayaks/testbt.pdf")

plk= [];

for sym in ls(fg) #plotting all syms labeled
    X1 = getKDEMean(getVertKDE(fg,sym))
    push!(plk, layer(x=[X1[1];],y=[X1[2];], Geom.point), Theme(default_color=colorant"green",point_size = 1.5pt,highlight_width = 0pt))
end
#
# for i in 1:pose_counter
#      X1 = getKDEMean(getVertKDE(fg,Symbol("x$i")))
#      push!(plk, layer(x=[X1[1];],y=[X1[2];], Geom.point), Theme(point_size = 1.5pt,highlight_width = 0pt))
# end
#
# push!(plk,layer(x=posData[:,1],y=posData[:,2], Geom.path, Theme(default_color=colorant"green")))
#
igt = [17.0499;1.7832];
push!(plk,layer(x=[igt[1];],y=[igt[2];], label=String["Beacon";],Geom.point,Geom.label(hide_overlaps=false), order=2, Theme(default_color=colorant"red")));
#
L1 = getVal(getVariable(fg, beacon))
K1 = plotKDEContour(getVertKDE(fg,:l1),xlbl="X (m)", ylbl="Y (m)",levels=5,layers=true);
push!(plk,K1...)
push!(plk,Gadfly.Theme(key_position = :none));
push!(plk, Coord.cartesian(xmin=-40, xmax=140, ymin=-150, ymax=75,fixed=true))

plkplot = Gadfly.plot(plk...); plkplot |> PDF("/media/data1/data/kayaks/testplot.pdf");

end
