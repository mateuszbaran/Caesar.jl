
mkdir(resultsdir)
mkdir(resultsdir*"/tags")
mkdir(resultsdir*"/images")


fid = open(resultsdir*"/readme.txt", "w")
println(fid, currdirtime)
println(fid, datafolder)
println(fid, camidxs)
println(fid, ARGS)
println(fid, "res.csv: wPx,wPy,wTh,bVx,bVy")
close(fid)

fid = open(resultsparentdir*"/racecar.log", "a")
println(fid, "$(currdirtime), $datafolder, $(camidxs), $(ARGS)")
close(fid)
