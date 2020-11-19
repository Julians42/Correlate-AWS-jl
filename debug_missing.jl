# Check WTT, LAF, USC, RUS 
# Check B1 

@everywhere begin 
    cc_step, cc_len = 3600, 3600
    maxlag, fs = 300., 20. # maximum lag time in correlation, sampling frequency
    freqmin, freqmax = 0.05, 9.9
    half_win, water_level = 30, 0.01
    aws = aws_config(region="us-west-2")
    bucket = "scedc-pds"
    bucket2 = "seisbasin"
    network = "CI"
    channel1 = "BH?"
    channel2 = "HH?"
    OUTDIR = "~/data"
end

start_date, end_date = "2019-01-01", "2019-12-31"
#full_days = Date(startdate):Day(1):Date(enddate)
function divide_months(t_start::String, t_end::String)
    """ Return all month windows """
    startdate, enddate = Date(t_start), Date(t_end)
    start_ym, end_ym = Dates.yearmonth(startdate), Dates.yearmonth(enddate)
    last_first, last_last = Dates.daysinmonth(startdate), Dates.daysinmonth(enddate)
    m_start1, m_start2 = Date("$(start_ym[1])-$(start_ym[2])-01"), Date("$(end_ym[1])-$(end_ym[2])-01") # start of first/last month
    m_end1, m_end2 = Date("$(start_ym[1])-$(start_ym[2])-$last_first"), Date("$(end_ym[1])-$(end_ym[2])-$last_last") # end of first/last month
    start_range = m_start1:Month(1):m_start2 # month start values
    end_range = m_end1:Month(1):m_end2 # month end values
    dates = [[start_range[ind], end_range[ind]] for ind in 1:length(start_range)] # start and end of each month
    return dates
end
# set up params 
days = Date(startdate):Day(1):Date(enddate)
@eval @everywhere startdate, enddate = $startdate, $enddate
@eval @everywhere days = $days
i=1
yr = Dates.year(days[i])
path = join([Dates.year(days[i]),lpad(Dates.dayofyear(days[i]),3,"0")],"_") # Yeilds "YEAR_JDY"

###################### Data Download ########################################
# filelist query for BH and HH 
# filelist_scedc_BH = s3query(aws, days[i], enddate = days[i], network=network, channel=channel1)
# filelist_scedc_HH = s3query(aws, days[i], enddate = days[i], network=network, channel=channel2)
ar_filelist = pmap(x -> s3query(aws, days[i], enddate = days[i], network=network, channel=x),[channel1, channel2])
filelist_scedc_BH = ar_filelist[1]
filelist_scedc_HH = ar_filelist[2]
# create dictionary and overwrite HH keys with available BH data
function get_dict_name(file::String)
    station = convert(String, split(split(file,"/")[end],"_")[1])
    component = split(file,"/")[end][10]
    return string(station, "_", component)
end

BH_keys = [get_dict_name(file) for file in filelist_scedc_BH]
HH_keys = [get_dict_name(file) for file in filelist_scedc_HH]

# Convert to dictionary 
HH_dict = Dict([(name, file) for (name, file) in zip(HH_keys, filelist_scedc_HH)]) 
BH_dict = Dict([(name, file) for (name, file) in zip(BH_keys, filelist_scedc_BH)]) 
filelist_dict = merge(HH_dict, BH_dict) # BH dict overwrite HH_dict. This is essentually the union
filelist_scedc = collect(values(filelist_dict)) # return values as array for download


try
    ec2download(aws, bucket, filelist_scedc, OUTDIR)
    data_avail = true
catch
    println("Error Downloading SCEDC data for $path. Potentially no data available.")
end

dict = collect(s3_list_objects(aws, "seisbasin", "continuous_waveforms/$(yr)/$(path)/", max_items=1000))
filelist_basin = Array{String,1}(undef,length(dict))
#Index to filepath given by the "Key" element of the dictionary
for ind in 1:length(dict)
    filelist_basin[ind] = dict[ind]["Key"]
end
@eval @everywhere filelist_basin=$filelist_basin

try
    ec2download(aws, bucket2, filelist_basin, OUTDIR)
    data_avail = true
catch
    println("Error Downloading seisbasin data for $path. Potentially no data available.")
end

################### Add Location Data ##############################
#### add location data

# merge source and receiver dataframes to add
sources = DataFrame(CSV.File("files/source_locations.csv"))
receivers = DataFrame(CSV.File("files/receiver_locations.csv"))
all_stations = deepcopy(receivers)
# all_locations = join(sources, receivers, on = :station, kind = :outer) #should be able to join but not working
for row in eachrow(sources) # silly loop - plz don't ever iterate rows 
    push!(all_stations, row)
end 

# load data
fpaths = readdir("/home/ubuntu/data/continuous_waveforms/$(Dates.year(days[i]))/$(path)")
files = joinpath.("/home/ubuntu/data/continuous_waveforms/$(Dates.year(days[i]))/$(path)",fpaths)

T_load = @elapsed ar_file = pmap(x->load_file(x), files[1:200]) # load data - trial sized :) 
ar = [elt[1] for elt in ar_file if isnothing(elt)==false]
clean_files = [elt[2] for elt in ar_file if isnothing(elt)==false]

function LLE_geo(station, df)
    """ Find station matching location and return geoloc object"""
    try
        row = df[(findfirst(x -> x==station, df.station)),:]
        lat, lon, el = row.latitude[1], row.longitude[1], row.elevation[1]
        geo = GeoLoc(lat = float(lat), lon = float(lon), el = float(el))
        return geo
    catch 
        return nothing
    end
end

function add_locations(ar::Array{SeisData,1},df::DataFrame)
    good_indices = Array{Int32 ,1}(undef, 0)
    for (ind, chn) in enumerate(ar)
        name = split(chn.name[1],".")[2]
        geo = LLE_geo(name, df)
        if !isnothing(geo)
            chn.loc[1] = geo
            push!(good_indices, ind)
        else
            println("Station $name doesn't have a location in the dataframe")
        end
    end
    return good_indices
end
good_indices = add_locations(ar, all_stations)
 
# get only stations which have locations in CSV to correlate
ar = ar[good_indices] # probably shouldn't deepcopy - wastes time but cleaner for debugging

###################### Preprocess #######################

T_preprocess = @elapsed fft_raw = pmap(x -> preprocess(x, fs, freqmin, freqmax, cc_step, cc_len, half_win, water_level), ar)

ffts = [fft[1] for fft in fft_raw] # extract ffts from raw array
bools = [fft[2] for fft in fft_raw] # extract processing success/failure bools from raw array
println("Data for $(days[i]) preprocessed in $T_preprocess seconds.")
ffts = ffts[bools]
# ffts, ar, clean_files = ffts[bools], ar[bools], clean_files[bools]
# ar = ar[bools]
# clean_files = clean_files[bools]
if any(bools == 0) # report if some channels failed in preprocessing
    num_bad_preprocess = length([bool for bool in bools if bool ==1])
    println("$num_bad_preprocess channels failed in preprocessing. $(length(ar)) channels to be correlated.")
end

###################### Index Pairs and Correlate ###############################

to_correlate = [split(convert(String,fft.name),".")[2]*fft.name[end] for fft in ffts]

function correlate_indices(to_correlate::Array{String, 1}, sources::Array{String,1})
    pairs = Array{Array{Int64,1}}(undef, 0) #array of station pairs to correlate
    source_indices = Array{Int64, 1}(undef, 0)
    # Find stations in successfully preprocessed ffts which are sources
    for (ind, station) in enumerate(to_correlate)
        loc = findfirst(occursin.(station[1:end-1], sources))
        if !isnothing(loc)
            push!(source_indices, ind)
        end
    end
    # get correlation pairs - all sources to all recievers. 
    for source_loc in source_indices
        for (ind, rec_loc) in enumerate(to_correlate)
            push!(pairs, [source_loc, ind])
        end
    end
    return pairs 
end

correlate_pairs = correlate_indices(to_correlate, sources)

# correlate
T2 = @elapsed pmap(x -> correlate_pair(x, maxlag), map(y -> ffts[y], correlate_pairs))

println("Data for $(days[i]) correlated in $(T2) seconds!")











#Returns indices of source stations at index 1 and non-source stations at index 2
function index_sources(ar::Array{String,1}, stations::Array{String,1})
    indices = Array{Int64,1}(undef,0)
    for i in 1:length(stations)
        for j in 1:length(ar)
            if occursin(stations[i],ar[j]) == true
                push!(indices, j)
            end
        end
    end
    not_indices = indices#setdiff(1:length(ar), indices)
    return([indices,not_indices])
end

function station_pairs(indices::Array{Array{Int64,1}}) # returns array of station pairs to correlate
    pairs = Array{Array{Int64,1}}(undef, 0) #array of station pairs to correlate
    for i in 1:length(indices[1])
        for j in 1:length(indices[2]) # add distance checking - eg don't add anything over 300 km
            push!(pairs, [indices[1][i],indices[2][j]])
        end
    end
    return pairs
end









############################ Data Download ###################################
filelist_scedc = s3query(aws, days[i], enddate = days[i], network=network, channel=channel)
filelist_scedc2 = vcat(filelist_scedc[occursin.("IPT", filelist_scedc)], filelist_scedc[occursin.("CHN", filelist_scedc)])
@eval @everywhere filelist_scedc=$filelist_scedc
# Dowload Data and read file paths - replace with ec2stream when available
data_avail = false


#S3 query call for data file information



####################### Read and Preprocess ####################################
fpaths = readdir("/home/ubuntu/data/continuous_waveforms/$(Dates.year(days[i]))/$(path)")
files = joinpath.("/home/ubuntu/data/continuous_waveforms/$(Dates.year(days[i]))/$(path)",fpaths)

T_load = @elapsed ar_file = pmap(x->load_file(x), files) # load data 
ar = [elt[1] for elt in ar_file if isnothing(elt)==false]
add_locations(ar, df) # add source locations
clean_files = [elt[2] for elt in ar_file if isnothing(elt)==false]
println("Data for $(days[i]) loaded in $T_load seconds. $(length(ar)) channels to be correlated, with $(length(ar_file)-length(ar)) channels discarded.")

T_preprocess = @elapsed fft_raw = pmap(x -> preprocess(x, fs, freqmin, freqmax, cc_step, cc_len, half_win, water_level), ar)

ffts = [fft[1] for fft in fft_raw] # extract ffts from raw array
bools = [fft[2] for fft in fft_raw] # extract processing success/failure bools from raw array
println("Data for $(days[i]) preprocessed in $T_preprocess seconds.")
ffts, ar, clean_files = ffts[bools], ar[bools], clean_files[bools]
ar = ar[bools]
clean_files = clean_files[bools]
if any(bools == 0) == true # report if some channels failed in preprocessing
    num_bad_preprocess = length([bool for bool in bools if bool ==1])
    println("$num_bad_preprocess channels failed in preprocessing. $(length(ar)) channels to be correlated.")
end

###################### Index Pairs and Correlate ###############################

indices = index_sources(clean_files, sources) # returns indices of sources
sta_pairs = station_pairs(indices)

# correlate
T2 = @elapsed pmap(x -> correlate_pair(x, maxlag), map(y -> ffts[y], sta_pairs))

println("Data for $(days[i]) correlated in $(T2) seconds!")

# Perform cleanup of instance
rm("data/continuous_waveforms", recursive=true) # Remove raw data to prevent memory crash 


#     # combine single day data to month files by station pair
#     @eval @everywhere station_pair_names, month_, yr = readdir("/home/ubuntu/CORR"), Dates.monthname(Date(startdate)),Dates.year(Date(startdate)) 
#     # month = Dates.monthname(Date(startdate)) # get the name of the month
#     # yr = Dates.year(Date(startdate))

#     if !isdir("home/ubuntu/corr_large/$month_")
#         mkpath("home/ubuntu/corr_large/$month_")
#     end
#     if !isdir("month_index/$yr")
#         mkpath("month_index/$yr")
#     end

#     jld_time = @elapsed pmap(x -> write_jld2(x, "corr_large/$yr/$month_"), station_pair_names) # combine corrs by station pair and write to single file 

#     # as station pair names are filenames, we save filenames in a csv to read back during post-process 
#     df = DataFrame(Files = station_pair_names, paths =[string("corr_large/$yr/$month_/",elt,".jld2") for elt in station_pair_names])
#     CSV.write("month_index/$yr/$(month_).csv",df)

#     ################### Transfer to S3 ##########################

#     s3_put(aws, "seisbasin", "month_index/$yr/$(month_).csv", read("month_index/$yr/$(month_).csv"))

#     month_files = joinpath.("corr_large/$yr/$month_", readdir("corr_large/$yr/$month_"))
#     Transfer = @elapsed pmap(x ->s3_put(aws, "seisbasin", x, read(x)), month_files)
#     println("$(length(month_files)) correlation files transfered to $(bucket2) in $Transfer seconds!") 


#     println("$num_corrs total correlations processed")
#     T_end = Dates.now()
#     println(T_end-T_start)
#     ############# Clean Up #################
#     rm("CORR", recursive=true) # Remove single correlation data 
#     rm("corr_large/$yr/$month_", recursive=true) #remove large correlation data
# end


BH = Set([split(split(file,"/")[end],"_")[1] for file in files2])
HH = Set([split(split(file,"/")[end],"_")[1] for file in files1])
issubset(BH, HH)

function index_sources(ar::Array{String,1})
    """ Index function for n^2 problem """
    pairs = Array{Int64,1}(undef,0)
    for i in 1:(length(ar)-1)
        for j in (i+1):length(ar)
            push!(pairs, [i ,j])
        end
    end
    return pairs
end







m_dict = Dict(:Year =>  2019, :Month =>  "February", :channels =>  17, :correlations =>  17, :time => Dates.Millisecond(12), :size_raw => 8.9, :size_corr => float(15))



filelist_scedc_BH =  [ "continuous_waveforms/2019/2019_001/CIADO__BHE___2019001.ms", 
 "continuous_waveforms/2019/2019_001/CIADO__BHN___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIADO__BHZ___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIALP__BHE___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIALP__BHN___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIALP__BHZ___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIARV__BHE___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIARV__BHN___2019001.ms",]


 filelist_scedc_HH = [ "continuous_waveforms/2019/2019_001/CIADO__HHE___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIADO__HHN___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIADO__HHZ___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIALP__HHE___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIALP__HHN___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIALP__HHZ___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIARV__HHE___2019001.ms",
 "continuous_waveforms/2019/2019_001/CIARV__HHN___2019001.ms"]



  fname = "2017_017_CI.IPT..CI.ARV_ZZ.jld2"
 fname2 = "test.h5"
 comp="ZZ"
 function save_hdf5(C::CorrData, name)
       D=Dict([ ("corr_type",C.corr_type), ("cc_len",C.cc_len),("cc_step",C.cc_len),
        ("whitened",C.whitened), ("time_norm",C.time_norm), ("notes",C.notes),("dist",C.dist),
        ("azi",C.azi),("baz",C.baz),("maxlag",C.maxlag)])
        # here i should convert the *t* as a date into a unix time.
        T = convert(Int,C.t[1] * 1e6)
        h5open(name,"w") do file
            g=g_create(file,"stack")
            g[C.comp]=C.corr[:]
            attrs(g)["Description"] = "linear stack"
        end
    end
C=load_corr(fname,comp)
save_hdf5(C,fname2)