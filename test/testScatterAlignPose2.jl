# test ScatterAlignPose2

using Test
using Images
using Caesar
using Distributions
using Manifolds

# test plotting helper functions
using Gadfly
using Random

import Rotations as _Rot

##
@testset "Test ScatterAlignPose2" begin
##

x = -10:0.1:10;
y = -10:0.1:10;

x = -10:0.1:10;

σ = 0.1

g = (x,y)->pdf(MvNormal([3.;0],[σ;σ]),[x;y]) + pdf(MvNormal([8.;0.0],[σ;σ]),[x;y]) + pdf(MvNormal([0;5.0],[σ;σ]),[x;y])

bIM1 = zeros(length(x),length(y))
bIM2 = zeros(length(x),length(y))

oT = [2.; 0]
oΨ =  pi/6

M = SpecialEuclidean(2)
e0 = identity_element(M)
pCq = [oT;oΨ]
pTq = affine_matrix(M, exp(M, e0, hat(M, e0, pCq)))

##

for (i,x_) in enumerate(x), (j,y_) in enumerate(y)
  bIM1[i,j] = g(x_,y_)
  v = pTq*[x_;y_;1.0]
  _x_, _y_ = v[1], v[2]
  bIM2[i,j] = g(_x_, _y_)
end

sap = ScatterAlignPose2(bIM1, bIM2, (x,y); sample_count=100, bw=1.0, cvt=(im)->im)

# requires IIF at least v0.25.6
@test sample(sap.hgd1,1) isa Tuple
@test sample(sap.hgd2,10)[1] isa AbstractArray

## test plotting function

snt = overlayScatterMutate(sap; sample_count=50, bw=1., user_coords=[0.;0;0]); # , user_offset=[0.;0;0.]);
plotScatterAlign(snt; title="\npCq=$(round.(pCq,digits=2))")

##

# inverse for q --> p
@test isapprox( oT, snt.best_coords[1:2]; atol=0.3 )
@test isapprox( oΨ, snt.best_coords[3]; atol=0.2 )



## check packing and unpacking

psap = convert(PackedScatterAlignPose2, sap);
sap_ = convert(ScatterAlignPose2, psap);

@test sap.gridscale == sap_.gridscale
@test sap.sample_count == sap_.sample_count
@test sap.bw == sap_.bw

@test isapprox(sap.hgd1, sap_.hgd1, mmd_tol=1e-2)
@test isapprox(sap.hgd2, sap_.hgd2, mmd_tol=1e-2)

## check that optimize works (using the same tfg)

tfg = initfg()
getSolverParams(tfg).attemptGradients = false
M = getManifold(sap)
e0 = identity_element(M)
meas = sample(sap.hgd1,100)[1], [ProductRepr(sample(sap.hgd2,1)[1][1],[1 0; 0 1.]) for _ in 1:100], M
δ(x) = calcFactorResidualTemporary(sap, (Pose2,Pose2), meas, (e0,ProductRepr(x[1:2],_Rot.RotMatrix(x[3]))) , tfg=tfg)[1]

@show δ([0;0;0.]);
@show δ([1.;0;0.]);

@test isapprox(δ([0;0;0.]), δ([0;0;0.]); atol=1e-6)
@test isapprox(δ([10;0;0.]), δ([10;0;0.]); atol=1e-6)
@test !isapprox( δ([0;0;0.]), δ([0.1;0;0.]), atol=1e-6 )
@test !isapprox( δ([0;0;0.]), δ([0;0;0.1]), atol=1e-6 )



## use in graph

fg = initfg()
getSolverParams(fg).inflateCycles=1

addVariable!(fg, :x0, Pose2)
addVariable!(fg, :x1, Pose2)

addFactor!(fg, [:x0;], PriorPose2(MvNormal([0.01;0.01;0.01])))
addFactor!(fg, [:x0;:x1], sap, inflation=0.0)

X1 = approxConvBelief(fg, :x0x1f1, :x1)

c1 = AMP.makeCoordsFromPoint(getManifold(Pose2), mean(X1))

# @warn "skipping numerical check on ScatterAlignPose2 convolution test" c1
@test isapprox( oT, c1[1:2], atol=0.5 )
@test isapprox( oΨ, c1[3],   atol=0.3 )


##
end


@testset "test ScatterAlignPose2 with MKD direct" begin
##

# setup

oT = [2.; 0]
oΨ =  pi/6

M = SpecialEuclidean(2)
e0 = identity_element(M)
pCq = [oT;oΨ]
pTq = affine_matrix(M, exp(M, e0, hat(M, e0, pCq)))

##

# Points in XY only

p1 = vcat([randn(2) for i in 1:50], [randn(2)+[0;10] for i in 1:50], [randn(2)+[10;0] for i in 1:50])
shuffle!(p1)
P1 = manikde!(getManifold(Point2), p1)

p2 = vcat([randn(2)+[3;0] for i in 1:50], [randn(2)+[3;10] for i in 1:50], [randn(2)+[13;0] for i in 1:50])

# adjust points
for (i,pt) in enumerate(p2)
  v = pTq*[pt;1.0]
  pt[1:2] .= v[1:2]
end

shuffle!(p2)
P2 = manikde!(getManifold(Point2), p2)

sap = ScatterAlignPose2(;hgd1=P1, hgd2=P2, sample_count=100, bw=2.0)

##

fg = initfg()
getSolverParams(fg).inflateCycles=1

addVariable!(fg, :x0, Pose2)
addVariable!(fg, :x1, Pose2)

addFactor!(fg, [:x0], PriorPose2(MvNormal([0.01;0.01;0.01])))

## check residual calculation

# see #1415
meas = sample(P1,100)[1], [ProductRepr([0;0.],[1 0; 0 1.]) for _ in 1:100], M
δ1 = calcFactorResidualTemporary(sap, (Pose2,Pose2), meas, (e0,e0))

meas = sample(P1,100)[1], [ProductRepr(sample(P2,1)[1][1],[1 0; 0 1.]) for _ in 1:100], M
δ2 = calcFactorResidualTemporary(sap, (Pose2,Pose2), meas, (e0,e0))

# check different cloud samplings produce different residual values
@test !isapprox(δ1, δ2,  atol=1e-4)

## check that optimize works (using the same tfg)

tfg = initfg()
meas = sample(P1,100)[1], [ProductRepr(sample(P2,1)[1][1],[1 0; 0 1.]) for _ in 1:100], M
δ(x) = calcFactorResidualTemporary(sap, (Pose2,Pose2), meas, (e0,ProductRepr(x[1:2],_Rot.RotMatrix(x[3]))), tfg=tfg)[1]

@show δ([0;0;0.])
@show δ([1.;0;0.])

@test !isapprox( δ([0;0;0.]), δ([1.;0;0.]), atol=1e-6 )


## test plotting function

snt = overlayScatterMutate(sap; sample_count=100, bw=2.0);
plotScatterAlign(snt; title="\npCq=$(round.(pCq,digits=2))")


##

# inverse for q --> p
@test isapprox( oT, snt.best_coords[1:2]; atol=1.0 )
@test isapprox( oΨ,   snt.best_coords[3]; atol=0.5 )

##

doautoinit!(fg, :x0)

addFactor!(fg, [:x0;:x1], sap)
X1 = approxConvBelief(fg, :x0x1f1, :x1)
c1 = AMP.makeCoordsFromPoint(getManifold(Pose2), mean(X1))

##
end

#