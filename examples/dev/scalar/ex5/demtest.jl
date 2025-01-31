#=
Load a DEM as a Point3 set in a factor graph
=#

using Images
using ImageView
using FileIO
using Interpolations
using Caesar
using RoME
using RoME: MeanMaxPPE
using ProgressMeter
using TensorCast

using TensorCast
using Cairo
using RoMEPlotting
using Gadfly
Gadfly.set_default_plot_size(35cm, 25cm)
using ImageMagick

## only run this if planning big solves

using Distributed
# localprocs
# addprocs(5);

##

if true
  machines = []
  allmc = split(ENV["JL_CLUSTER_HY"], ';')
  for mc in allmc
    push!(machines, (mc,20))
  end
  prc_rmt = addprocs(machines)
end

##

using Caesar, Cairo, RoMEPlotting
@everywhere using Caesar
@everywhere using Cairo, RoMEPlotting
@everywhere Gadfly.set_default_plot_size(35cm,25cm)




##

@everywhere prjPath = pkgdir(Caesar)

@everywhere include(joinpath(prjPath,"examples/dev/scalar/CommonUtils.jl"))
@everywhere using .CommonUtils

##


# # load dem (18x18km span, ~17m/px)
x_min, x_max = -9000, 9000
y_min, y_max = -9000, 9000
# north is regular map image up
x, y, img = RoME.generateField_CanyonDEM(1, 100, x_is_north=false, x_min=x_min, x_max=x_max, y_min=y_min, y_max=y_max)

# imshow(img)


## modify to generate elevation measurements (data/smallData as in Boxy) and priors

dem = Interpolations.LinearInterpolation((x,y), img) # interpolated DEM
elevation(p) = dem[getPPE(fg, p, :simulated).suggested[1:2]'...]
sigma_e = 0.01 # elevation measurement uncertainty

## test buildDEMSimulated

im = (j->((i->dem[i,j]).(x))).(y);
@cast im_[i,j] := im[j][i];
@assert norm(im_ - img) < 1e-10

##


function cb(fg_, lastpose)
  global dem, img
  
  # query DEM at ground truth
  z_e = elevation(lastpose)
  
  # generate noisy measurement
  @info "Callback for DEM LevelSet priors" lastpose ls(fg_, lastpose) z_e
  
  # create prior
  hmd = LevelSetGridNormal(img, (x,y), z_e, sigma_e, N=10000, sigma_scale=1)
  pr = PartialPriorPassThrough(hmd, (1,2))
  addFactor!(fg_, [lastpose], pr, tags=[:DEM;], graphinit=false, nullhypo=0.1)
  nothing
end


## Testing 

# 0. init empty FG w/ datastore
fg = initfg()
storeDir = joinLogPath(fg,"data")
mkpath(storeDir)
datastore = FolderStore{Vector{UInt8}}(:default_folder_store, storeDir) 
addBlobStore!(fg, datastore)

# new feature, going to temporarily disable as WIP
getSolverParams(fg).attemptGradients = false


##

# 1. load DEM into the factor graph
# point uncertainty - 2.5m horizontal, 1m vertical
# horizontal uncertainty chosen so that 3sigma is approx half the resolution
if false
  sigma = diagm([2.5, 2.5, 1.0])
  @time loadDEM!(fg, img, (x), (y), meshEdgeSigma=sigma);
end

##

# 2. generate trajectory 

μ0 = [-7000;-2000.0;pi/2]
@time generateCanonicalFG_Helix2DSlew!(11, posesperturn=30, radius=1500, dfg=fg, μ0=μ0, graphinit=false, postpose_cb=cb) #, slew_x=1/20)
deleteFactor!(fg, :x0f1)

# ensure specific solve settings
getSolverParams(fg).useMsgLikelihoods = true
getSolverParams(fg).graphinit = false
getSolverParams(fg).treeinit = true


## optional prior at start

mu0 = getPPE(fg, :x0, :simulated).suggested
pr0 = PriorPose2(MvNormal(mu0, 0.01.*[1;1;1;]))
addFactor!(fg, [:x0], pr0)

## for debugging

# getSolverParams(fg).drawtree = true
# getSolverParams(fg).showtree = true

# doautoinit!(fg, :x1)
# initAll!(fg)

# smtasks = Task[]
# tree, _, = solveTree!(fg; smtasks, recordcliqs=ls(fg))
# repeatCSMStep!(hists[3],6)

##


for i in 1:10

smtasks = Task[];
tree = solveTree!(fg; storeOld=true , smtasks ); 

end

##

# mkdir("/tmp/caesar/results")
# mkdir("/tmp/caesar/results/scalar")
# # starting from 1, solve a total of LAST+STEP-1 number of times, plotting after each STEP number of solves
# STEP, LAST = 5, 41
# for (a,z) in [(i%STEP,i+STEP-1) for i in 1:STEP:LAST]
#   for _ in a:z
#     solveTree!(fg, storeOld=true);
#   end
#   plotSLAM2D(fg, drawContour=false, drawPoints=false, drawEllipse=true) |> PDF("/tmp/caesar/results/scalar/h1500_150_01nh_$(z).pdf",20cm,20cm)
# end


##

plotSLAM2D_KeyAndRef(fg)


##

# function plotSLAM2D_Scalar(fg, img)
pl_ = plotSLAM2D(fg, solveKey=:simulated, 
                    x_off=-x_min, y_off=-y_min, 
                    scale=100/(x_max-x_min), 
                    drawContour=false, drawPoints=false, drawEllipse=false, 
                    manualColor="black", drawTriads=false);
#

# IGNORE VIZ OF THIS PLOT SINCE SPY INTERNALLY DOES A TRANSPOSE FROM [i,j]' --> (x,y) 
pl_m = Gadfly.spy(img')

##

union!(pl_.layers, pl_m.layers); pl_


##

## redraw z_e level to see if index orders are right

locs = (x->getPPE(fg[x], :simulated).suggested[1:2]).(sortDFG(ls(fg)))
# PartialPriorPassThrough type, with a LevelSetGridNormal
z_es = (x->getFactorType(fg[x]).Z.level).(sortDFG(lsf(fg, tags=[:DEM;])))
@cast locs_[j,i] := locs[j][i]

Gadfly.plot(x=locs_[:,1], y=locs_[:,2], color=z_es)


## check level set
_roi = img .- z_es[50]
# DEPRECATED USE NEW LevelSetGridNormal and HeatmapDensityGrid
# kp, weights = IIF.sampleLevelSetGaussian!(_roi, sigma_e, x, y)

Gadfly.plot(x=kp[1,:],y=kp[2,:], color=weights, Geom.Geom.point)

# imshow(st[3])

##

pl = plotHMSLevel(fg, :x47);

im = convert(Matrix{RGB}, pl);
# io = IOBuffer()
# stre = draw(PNG(io), pl)

# imshow(im)

##

vars = ls(fg) |> sortDFG
st = plotToVideo_Distributed( x->plotHMSLevel(fg, x), vars );

##

sks = listSolveKeys(fg) |> collect |> sortDFG
sks = [setdiff(sks, [:default]); :default]

# PL = plotSLAM2D_KeyAndSim(fg);

##

st = plotToVideo_Distributed( x->plotSLAM2D_KeyAndSim(fg, x), sks);

##

# check: query variables
getPPE(fg, :x0, :simulated).suggested
getPPE(fg, :pt50_50, :simulated).suggested

# check: fetch and plot pose variables

traj = ls(fg, r"x\d+") |> sortDFG
traj_xy = traj .|> x->getPPE(fg, x, :simulated).suggested[1:2]

@cast _xy[i,j] := traj_xy[i][j]

plot(
    layer(x=_xy[:,1],y=_xy[:,2], Geom.point),
    layer(x=_xy[:,1],y=_xy[:,2], Geom.path)
)

# 3. simulate elevation measurements
dem = Interpolations.LinearInterpolation((x,y), img) # interpolated DEM
elevation(p) = dem[getPPE(fg, p, :simulated).suggested[1:2]'...]

poses = ls(fg, r"x\d+") |> sortDFG

# fetch interpolated elevation at ground truth position 

for p in poses
    e = elevation(p) 

    # add to variable
    
end

# 4a. add pairwise constraints between poses and points

# 4b. add pairwise constraints between poses (cross-over)




## ================================================================================================ 
## DEV TESTING BELOW
## ================================================================================================ 


using ImageView
using UnicodePlots

imshow(img)

## Aliasing sampler on sparse selection of points

@info "DEM value range" minimum(img) maximum(img)



function getLevelSet(data,x, y, level, tol=0.01)
    """
    Get the grid positions at the specified height
    """
    roi = data.-level
    mask = abs.(roi) .< tol

    idx2d = findall(mask)  # 2D indices
    # idx   = i:length(idx)
    (v->[x[v.I[1]],y[v.I[2]]]).(idx2d)
end

# go bigger than measurement noise, to also accomodate heatmap sampling process errors
R_meas = 1e-4

# selection of interest, assume elevation measurement aroun d0.5 is of interest
level = 0.5
img_soi = img .- level
immask = abs.(img_soi) .< 0.01

imshow(immask)

img_sparse = img_soi[immask]
idx = findall(immask)

idx_pos = (v->[x[v[1]],y[v[2]]]).(idx)

x_spacing = x[2]-x[1]
y_spacing = y[2]-y[1]

# imgT = zeros(100,100)
# imgT[10,:] .= 1.0

# imshow(imgT)

# OPTION A
kerBw_ = 0.7*0.5*(x_spacing + y_spacing) # 70%
kerBw = [kerBw_; kerBw_]
@cast kerPos_[i,j] := idx_pos[j][i]
kerPos = collect(kerPos_)
P_pre = kde!(kerPos, kerBw)
pts_preIS = sample(P_pre, 10000)[1]

# draw flipped so consistent with imshow img[i,j] == img[x,y]
imscatter(img_) = scatterplot(img_[2,:], -img_[1,:])
imscatter(pts_preIS)

#
densityplot(pts_preIS[2,:], -pts_preIS[1,:])

# weigth the samples according to interpolated heatmap



# still need heatmap interpolation eval for weighting
# weight = heatmap(pts_preIS)
# R_meas helps control sample process sensitivity
hm = Interpolations.LinearInterpolation((x,y), img .- level ) # interpolated DEM

@cast vec_preIS[j][i] := pts_preIS[i,j]

delev = Vector{Float64}(undef, length(vec_preIS))

function hack(w_, i, u)
    w_[i] = hm(u...)
    nothing
end

##

using ProgressMeter

##

@showprogress 1 "wait what...?" for (i,u) in enumerate(vec_preIS)
  @show i, u
  if 9000 < abs(u[1]) || 9000 < abs(u[2]) 
    delev[i] = 0.0
    continue
  end
  hack(delev, i, u)
end

##

weights = exp.(-(0.5/R_meas)*(abs.(delev)).^2)
weights ./= sum(weights)

histogram(weights, nbins=20, closed=:left)

# get final kde

# bw = [0.1;0.1]
prior = kde!(pts_preIS, kerBw)



##


# # OPTION B
# # where are the values of interest
# # make a distribution
# img_sparse .^= 2
# img_pdf = exp.(-img_sparse*0.5/R_meas)
# img_pdf ./= sum(img_pdf)
# bss = AliasingScalarSampler([id_idx;]./1.0, img_pdf)
# id_smpls = rand(bss, 10000) .|> Int



# ## how to super sample massive low res grid 2D scalar field

# # binary threshold the gridded heatmap

# # OPTION A
# # P_pre is weighted KDE kernels with fat bandwidth at each grid point (scalar dictates weight of kernel)
# # pts_preIS = sample(P_pre, 10000)
# # weight = heatmap(pts_preIS)

# # OPTION B
# # get first "grid points of interest" from heatmap with aliasing sampler 
# # mush those grid points to loose clusters (conv with Guassian)

# # importance weight those loose cluster points against the heatmap-interpolated
# N = 1000
# ## how to build weighted KDE (not full DEM pipeline yet)
# # mock heatmap
# mock = MvNormal([0.0;0.0], [1.0 0.5; 0.5 1.0])
# pts = rand(Mv, N)
# # mock mask
# mask = pts[2,:] .< 0.5

# # importance weighted samples from "heatmap
# weights = ones(N)
# weights[mask] .= 0.01
# weights ./= sum(weights)
# postMushWeightedPts = pts

# bw = [0.1;0.1]
# # this is the KDE belief to build a prior for localizaton from low res map (final step)
# P = kde!(postMushWeightedPts, bw, weights)






##




##

using KernelDensityEstimatePlotting
Gadfly.set_default_plot_size(35cm,25cm)

plotKDE(prior)

#