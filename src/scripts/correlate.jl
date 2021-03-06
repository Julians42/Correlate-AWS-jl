T = @elapsed using SeisIO, SeisNoise, Plots, Dates, CSV, DataFrames, SCEDC, AWSCore, Distributed, JLD2, Statistics, PyCall, Glob, StructArrays, AWSS3, SeisIO.SEED

using Pkg 
ENV["GR"] = ""
Pkg.build("GR")

#Add procs to access multiple cores
addprocs()

# Read in station locations and list source stations
all_stations = DataFrame(CSV.File("files/modified_nodal.csv"))
sources = ["TA2","LPC","CJM", "IPT", "SVD", "SNO", "DEV"
        ,"VINE", "ROPE", "ARNO", "LUCI", "ROUF", "KUZD", "ALLI", "CHN", "USB", "Q0048"]
# PASC, RUS
# Integrate all stations starting with Q
@everywhere using SeisIO, SeisNoise, Dates, CSV, DataFrames,SCEDC, AWSCore, StructArrays, AWSS3, Statistics, JLD2, Glob, SeisIO.SEED
@everywhere begin 
    function is_window(C::SeisData, cc_len::Int64)
        """ Returns true if data has large enough ungapped window for correlation """
        windows = u2d.(SeisIO.t_win(C.t[1], C.fs[1]) .* 1e-6)
        startend = windows[:,2] .- windows[:,1] .> Second(cc_len)
        bool = any(startend)
        return bool
    end
    function load_file(file::String)
        """ Load raw data file """
        data = read_data("mseed", file)
        gaps = size(data.t[1])[1] # N-2 gaps (eg gaps = 12 tests for 10 gaps)
        pts = size(data.x[1])[1]
        fs_temp = data.fs[1]
        if gaps < 25 && is_window(data, cc_len) == true # If few gaps and sufficient (2/3) data present, data is clean
            return [data, file]
        end
    end
    function preprocess(S::SeisData, fs::Float64, freqmin::Float64, freqmax::Float64, cc_step::Int64, cc_len::Int64, half_win::Int64, water_level::Float64)
        """
            Pre-process raw seismic data object.
            - Removes mean from `S`.
            - Detrends each channel in `S`.
            - Tapers `S`
            - We recommend including `bandpass!` and `coherence` to improve signal
            - Downsamples data to sampling rate `fs`
            - Phase-shifts data to begin at 00:00:00.0
        """
        try
            process_raw!(S, fs)
            R = RawData(S,cc_len,cc_step)
            SeisNoise.detrend!(R)
            SeisNoise.taper!(R)
            bandpass!(R,freqmin,freqmax,zerophase=true)
            FFT = compute_fft(R) # Compute Fourier Transform
            coherence!(FFT,half_win, water_level)
            bool = true
            return [FFT, bool] 
        catch  e # Handle error catching if earlier filters haven't caught it yet
            println(e)
            bool = false
            return [nothing, bool]
        end
    end

    function cc_medianmute(A::AbstractArray, cc_medianmute_α::Float64 = 10.0)
        """
            Remove noisy correlation windows before stacking
            - Remove if average noise is greater than 10x the average
        """
        T, N = size(A)
        cc_maxamp = vec(maximum(abs.(A), dims=1))
        cc_medianmax = median(cc_maxamp)
        inds = findall(x-> x <= cc_medianmute_α*cc_medianmax,cc_maxamp)
        return A[:, inds], inds
    end
    remove_medianmute(C::CorrData, inds) = (return C.t[inds])
    function cc_medianmute!(C::CorrData, cc_medianmute_α::Float64 = 10.0)
        C.corr, inds = cc_medianmute(C.corr, cc_medianmute_α)
        C.t = remove_medianmute(C, inds)
        return nothing
    end
    function name_corr(C::CorrData)
        """ Returns corr name string: CH1.STA1.LOC1.CH2.STA2.LOC2 """
        return strip(join(deleteat!(split(C.name,"."),[4,8]),"."),'.')
    end
    function correlate_pair(ffts::Array{FFTData,1}, maxlag::Float64)
        """ 
            Correlation function for pair of fft data
            - noise filter and stacking
            - saves directly to disk: ensure directory is correct if not on AWS
        """
        C = correlate(ffts[1],ffts[2],maxlag)
        cc_medianmute!(C, 10.) # remove correlation windows with high noise
        stack!(C)
        pair, comp = name_corr(C), C.comp
        save_named_corr(C,"CORR/$pair/$comp")
    end
    function save_named_corr(C::CorrData, CORROUT::String)
        """ Implements custom naming scheme for project """
        CORROUT = expanduser(CORROUT) # ensure file directory exists
        if isdir(CORROUT) == false
            mkpath(CORROUT)
        end

        yr,j_day = Dates.year(Date(C.id)), lpad(Dates.dayofyear(Date(C.id)),3,"0") # YEAR, JULIAN_DAY
        p_name = name_corr(C) 
        name = join([yr,j_day,p_name],"_") #YEAR_JDY_CORRNAME

        # create JLD2 file and save correlation
        filename = joinpath(CORROUT,"$(name).jld2")
        file = jldopen(filename, "a+")
        if !(C.comp in keys(file))
            group = JLD2.Group(file, C.comp)
            group[C.id] = C
        else
            file[C.comp][C.id] = C
        end
        close(file)
    end
    function load_corrs(file_list::Array{String,1})
        corrs_in_pair = Array{CorrData,1}(undef, length(file_list))
        for (index, name) in enumerate(file_list)
            comp = string(split(name, "/")[end-1]) # get component
            corrs_in_pair[index] = load_corr(name, comp)
        end
        return corrs_in_pair
    end
    function write_jld2(corr_folder::String, file_dir::String)
        pair_corr_names = glob("$corr_folder/*/*.jld2","CORR")
        pair_corrs = load_corrs(pair_corr_names)
        if !isdir("$file_dir") # ensure filepathing
            mkpath("$file_dir")
        end
        fo = jldopen("$(file_dir)/$(corr_folder).jld2", "w") # name of the station pairs, most computationally expensive
        for (index, value) in enumerate(pair_corrs)
            # continue if no data in corr 
            isempty(value.corr) && continue
            #pair = join(deleteat!(split(corrs[index].name,"."),[3,4,7,8]),".")
            comp = value.comp
            starttime = string(Date(u2d(value.t[1]))) # eg 2017-01-01
            groupname = joinpath(comp, starttime)
            #!haskey(fo, pair) && JLD2.Group(fo, pair) # if it doesn't have pair, make pair layer
            !haskey(fo, comp) && JLD2.Group(fo, comp) # component layer
            !haskey(fo, groupname) && (fo[groupname] = value) # save corr into layer 
        end
        close(fo)
    end
end

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

#Add location from dataframe to array 
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
    """ Adds locations to array of seisdata from a dataframe """
    good_indices = Array{Int32 ,1}(undef, 0)
    for (ind, chn) in enumerate(ar)
        name = split(chn.name[1],".")[2]
        geo = LLE_geo(name, df)
        if !isnothing(geo)
            chn.loc[1] = geo
            push!(good_indices, ind)
        else
            #println("Station $name doesn't have a location in the dataframe")
        end
    end
    return good_indices
end

#Returns indices of source stations at index 1 and non-source stations at index 2
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

function get_dict_name(file::String)
    station = convert(String, split(split(file,"/")[end],"_")[1])
    component = split(file,"/")[end][10:12]
    return string(station, "_", component)
end

function foldersize(dir=".")
    """ returns total size of folder in GB """
    size = 0
    for (root, dirs, files) in walkdir(dir)
        size += sum(map(filesize, joinpath.(root, files)))
    end
    return size*10e-10
end

#coeffs - send to all cores
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

# select start/ enddate (Default calculates for entire month: eg start_date on 003 rounds to 001)
start_date, end_date = "2018-07-01", "2018-08-31"
yr = Dates.year(Date(start_date))
@eval @everywhere yr = $yr
dates = divide_months(start_date, end_date)
summary = DataFrame(Year = Int[], Month = String[], channels = Int[], correlations = Int[], time = Millisecond[], size_raw = Float64[], size_corr = Float64[])
#Dict(:Year =  , :Month =  , :channels =  , correlations =  , time = )
for mth in dates
    startdate, enddate = mth[1], mth[2]
    days = Date(startdate):Day(1):Date(enddate)
    @eval @everywhere startdate, enddate = $startdate, $enddate
    @eval @everywhere days = $days
    num_channels, num_corrs, raw_size, corr_size = 0, 0, 0, 0
    T_start = Dates.now()
    for i in 1:length(days)
        try
            yr = Dates.year(days[i])
            path = join([Dates.year(days[i]),lpad(Dates.dayofyear(days[i]),3,"0")],"_") # Yeilds "YEAR_JDY"
            println(path)
            ############################ Data Download ###################################
            # get BH and HH data - BH is smaller, but doesn't contain all stations
            ar_filelist = pmap(x -> s3query(aws, days[i], enddate = days[i], network=network, channel=x),[channel1, channel2])
            filelist_scedc_BH = ar_filelist[1]
            filelist_scedc_HH = ar_filelist[2]
            # create dictionary and overwrite HH keys with available BH data


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

            ####################### Read and Preprocess ####################################
            fpaths = readdir("/home/ubuntu/data/continuous_waveforms/$(Dates.year(days[i]))/$(path)")
            files = joinpath.("/home/ubuntu/data/continuous_waveforms/$(Dates.year(days[i]))/$(path)",fpaths)
            
            T_load = @elapsed ar_file = pmap(x->load_file(x), files) # load data 
            ar = [elt[1] for elt in ar_file if isnothing(elt)==false];
            good_indices = add_locations(ar, all_stations) # add source locations
            ar = ar[good_indices] # we only want to correlate data which has locations 
            #clean_files = [elt[2] for elt in ar_file if isnothing(elt)==false]
            println("Data for $(days[i]) loaded in $T_load seconds. $(length(ar)) channels to be correlated, with $(length(ar_file)-length(ar)) channels discarded.")

            T_preprocess = @elapsed fft_raw = pmap(x -> preprocess(x, fs, freqmin, freqmax, cc_step, cc_len, half_win, water_level), ar)

            ffts = [fft[1] for fft in fft_raw] # extract ffts from raw array
            bools = [fft[2] for fft in fft_raw] # extract processing success/failure bools from raw array
            println("Data for $(days[i]) preprocessed in $T_preprocess seconds.")
            #ffts, ar, clean_files = ffts[bools], ar[bools], clean_files[bools]
            ffts = ffts[bools]
            num_channels += length(ffts) # add number of channels to be processed to summary 
            if any(bools == 0) # report if some channels failed in preprocessing
                num_bad_preprocess = length([bool for bool in bools if bool ==1])
                println("$num_bad_preprocess channels failed in preprocessing. $(length(ar)) channels to be correlated.")
            end

            ###################### Index Pairs and Correlate ###############################
            # get station names to correlate
            to_correlate = [split(convert(String,fft.name),".")[2]*fft.name[end] for fft in ffts]
            # check station names for source name, then pair all stations to all recievers (including sources)
            correlate_pairs = correlate_indices(to_correlate, sources)
            num_corrs += length(correlate_pairs) # add total number of correlations to summary

            # correlate
            T2 = @elapsed pmap(x -> correlate_pair(x, maxlag), map(y -> ffts[y], correlate_pairs))
 
            println("Data for $(days[i]) correlated in $(T2) seconds!")

            raw_size +=foldersize("data")

            # Perform cleanup of instance
            rm("data/continuous_waveforms", recursive=true) # Remove raw data to prevent memory crash 
            GC.gc() # clean memory 
        catch e
            println("Difficulty processing $(days[i]). Unexpected error. Continuing to next day.")
        end
    end

    # combine single day data to month files by station pair
    @eval @everywhere station_pair_names, month_, yr = readdir("/home/ubuntu/CORR"), Dates.monthname(Date(startdate)),Dates.year(Date(startdate)) 
    # month = Dates.monthname(Date(startdate)) # get the name of the month
    # yr = Dates.year(Date(startdate))

    if !isdir("home/ubuntu/corr_large/$month_")
        mkpath("home/ubuntu/corr_large/$month_")
    end
    if !isdir("month_index/$yr")
        mkpath("month_index/$yr")
    end

    jld_time = @elapsed pmap(x -> write_jld2(x, "corr_large/$yr/$month_"), station_pair_names) # combine corrs by station pair and write to single file 

    # as station pair names are filenames, we save filenames in a csv to read back during post-process 
    df = DataFrame(Files = station_pair_names, paths =[string("corr_large/$yr/$month_/",elt,".jld2") for elt in station_pair_names])
    CSV.write("month_index/$yr/$(month_).csv",df)

    ################### Transfer to S3 ##########################

    s3_put(aws, "seisbasin", "month_index/$yr/$(month_).csv", read("month_index/$yr/$(month_).csv"))

    month_files = joinpath.("corr_large/$yr/$month_", readdir("corr_large/$yr/$month_"))
    Transfer = @elapsed pmap(x ->s3_put(aws, "seisbasin", x, read(x)), month_files)
    println("$(length(month_files)) correlation files transfered to $(bucket2) in $Transfer seconds!") 

    corr_size +=foldersize("corr_large/$yr/$month_")

    println("$num_corrs total correlations processed")

    ############# Clean Up and write to summary file #################
    rm("CORR", recursive=true) # Remove single correlation data 
    rm("corr_large/$yr/$month_", recursive=true) #remove large correlation data
    T_end = Dates.now()
    t_diff = T_end-T_start 
    m_dict = Dict(:Year =>  yr, :Month =>  month_, :channels =>  num_channels, :correlations =>  num_corrs, :time => t_diff, :size_raw => float(raw_size), :size_corr => float(corr_size))
    push!(summary, m_dict)
end
CSV.write("summary$(yr).csv", summary)
s3_put(aws, "seisbasin", "summary/summary($yr)_SB2_SB3.csv", read("summary$yr.csv"))
println("Done")

s3_list_objects(aws, "seisbasin", "continuous_waveforms/$(yr)/$(path)/", max_items=1000)





function rfft(R::RawData,dims::Int=1)
    FFT = rfft(R.x,dims)
    FFT.fft ./= fftfreq(length(C.corr)).* 1im .* 2π
    return FFTData(R.name, R.id,R.loc, R.fs, R.gain, R.freqmin, R.freqmax,
                 R.cc_len, R.cc_step, R.whitened, R.time_norm, R.resp,
                 R.misc, R.notes, R.t, FFT)
end