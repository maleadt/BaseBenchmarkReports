import Pkg;
Pkg.activate(@__DIR__)
Pkg.instantiate()

using Plots
using JSON3
using Dates
using Feather
using DataFrames
using Tar
using CodecZstd
using ProgressMeter
using Statistics
using Pkg
using TOML
using Measurements
using CSV
using AbstractTrees

query_recurse(date, prefix, thing::Number, key) = false
query_recurse(date, prefix, thing::String, key) = false
query_recurse(date, prefix, thing::JSON3.Array, key) = (filter)(
    x -> x != false,
    map(
        z -> query_recurse(date, vcat(prefix), z, key),
        thing
    )
)
function query_recurse(date, prefix, thing, key)
    d = Dict(thing)
    if haskey(d, key)
        # return prefix => NamedTuple{(key,:date)}((d[key],date))
        return prefix => (
            time=d[:time],
            allocs=d[:allocs],
            memory=d[:memory],
            gctime=d[:gctime]
        )
        # return prefix
    else
        xs = [query_recurse(date, vcat(prefix, k), d[k], key) for k in keys(d)]
        filter!(x -> x != false, xs)
        return xs
        # return findfirst(map(k -> query_recurse(thing[k], key), for k in keys(thing)))
    end
end

get_singleton(x::Symbol) = x
get_singleton(::Nothing) = "a"
function get_singleton(xs)
    if xs isa Pair
        return xs
    elseif length(xs) == 0
        return xs
    elseif length(xs) == 1
        return get_singleton(xs[1])
    elseif length(xs[1]) == 0
        return get_singleton(xs[2:end])
    else
        return map(get_singleton, xs)
    end
end

function extract_recurse(date, group, thing)
    results = query_recurse(date, group, thing, :time)
    zs = filter(x -> length(x) != 0, results) |> get_singleton

    if zs isa Pair
        return [zs]
    end
    pair_level = filter(z -> z isa Pair, zs)
    vec_level = reduce(vcat, filter(z -> z isa Vector && length(z) > 0, zs), init=[])

    # Filter out :data from pair_level first elements -- this is a hack to get 
    # around tree recursion poorly.
    for (i, pair) in enumerate(pair_level)
        data_field_removed = filter(x -> x != :data, pair.first)
        pair_level[i] = data_field_removed => pair.second
    end


    return vcat(pair_level, vec_level)
end

# Accepts a JSON3 object and returns a DataFrame
function extract_statistics(date, benchmark_json)
    # Extract the statistics from the JSON3 object
    julia_version = benchmark_json[1]["Julia"]
    all_data = benchmark_json[2][1][2]["data"]
    # all_tags = benchmark_json[2][1][2]["tags"] # TODO support tags, though they don't seem very usefull.

    # all_data usually looks like this:
    # 
    # JSON3.Object{Vector{UInt8}, SubArray{UInt64, 1, Vector{UInt64}, Tuple{UnitRange{Int64}}, true}} with 20 entries:
    #   :shootout  => Any["BenchmarkGroup", {…
    #   :string    => Any["BenchmarkGroup", {…
    #   :linalg    => Any["BenchmarkGroup", {…
    #   :parallel  => Any["BenchmarkGroup", {…
    #   :find      => Any["BenchmarkGroup", {…
    #   :tuple     => Any["BenchmarkGroup", {…
    #   :dates     => Any["BenchmarkGroup", {…
    #   :micro     => Any["BenchmarkGroup", {…
    #   :io        => Any["BenchmarkGroup", {…
    #   :scalar    => Any["BenchmarkGroup", {…
    #   :sparse    => Any["BenchmarkGroup", {…
    #   :broadcast => Any["BenchmarkGroup", {…
    #   :union     => Any["BenchmarkGroup", {…
    #   :simd      => Any["BenchmarkGroup", {…
    #   ⋮          => ⋮

    # Now we loop through each group in all_data and extract the statistics.
    # Not type stable but fuck it
    res = []
    for (group, v1) in all_data
        append!(res, extract_recurse(date, vcat(julia_version, group), v1[2]))
    end
    return res
end

function treefindall(element, symbol::Symbol)
    # Find all elements in the tree that are a symbol
    res = []
    for element in PreOrderDFS(element)
        if element isa Pair
            if element.first == symbol
                push!(res, element)
            end
        end
    end
    return res
end

function read_data(root=joinpath(@__DIR__, "..", "..", "benchmark", "by_date"); limit=Inf)
    months = filter(readdir(root)) do dir
        contains(dir, r"^\d\d\d\d-\d\d$")
    end

    date_dirs = String[]
    for month in months
        days = filter(readdir(joinpath(root, month))) do dir
            contains(dir, r"^\d\d$")
        end
        for day in days
            push!(date_dirs, joinpath(month, day))
        end
    end

    # Cap date_dirs at limit
    if limit < length(date_dirs)
        date_dirs = date_dirs[1:limit]
    end

    mean_res = []
    std_rs = []
    minimum_res = []
    median_res = []
    date_res = Date[]
    @showprogress for date_dir in date_dirs
        date = Date(date_dir, "yyyy-mm/dd")

        data_file = joinpath(root, date_dir, "data.tar.zst")
        if !isfile(data_file)
            @debug "No data file found for $date"
            continue
        end

        mktempdir() do dir
            # begin
            open(data_file) do io
                stream = ZstdDecompressorStream(io)
                Tar.extract(stream, dir)
            end

            # Get the mean/median/minimum/std files.
            # They follow the format:
            #   ff14eafd803558f4c1f9ecdeecc44d3a4caa7343_primary.mean.json
            files = readdir(dir)

            if length(files) > 0
                @debug "Reading $date" files
                mean_file = filter(z -> occursin("mean", z), files) |> only
                std_file = filter(z -> occursin("std", z), files) |> only
                minimum_file = filter(z -> occursin("minimum", z), files) |> only
                median_file = filter(z -> occursin("median", z), files) |> only

                # @info "Reading $date" mean_file std_file minimum_file median_file

                # Read the files into JSON
                mean_dat = JSON3.read(joinpath(dir, mean_file))
                std_dat = JSON3.read(joinpath(dir, std_file))
                minimum_dat = JSON3.read(joinpath(dir, minimum_file))
                median_dat = JSON3.read(joinpath(dir, median_file))

                mean_stats = extract_statistics(date, mean_dat)
                std_stats = extract_statistics(date, std_dat)
                minimum_stats = extract_statistics(date, minimum_dat)
                median_stats = extract_statistics(date, median_dat)

                append!(mean_res, mean_stats)
                append!(std_rs, std_stats)
                append!(minimum_res, minimum_stats)
                append!(median_res, median_stats)
                append!(date_res, repeat([date], length(mean_stats))) # Tracks the date for each tuple we get.
            end

            # @info dir readdir(dir)
        end
    end

    # 
    filterdata(xs) = filter(x -> x != :data, xs)
    function tidy_results(data)
        version_categories = map(filterdata, [d[1] for d in data])
        time_data = [d[2] for d in data]
        return collect(v => t for (v, t) in zip(version_categories, time_data))
    end


    return (
        mean=mean_res |> tidy_results,
        std=std_rs |> tidy_results,
        minimum=minimum_res |> tidy_results,
        median=median_res |> tidy_results,
        date=date_res,
    )
end

# Grab all the data
df = read_data();
unique_keys = unique(d[1] for d in df.mean)

versions = [i[1][1] for i in df.mean]
unique_versions = sort(unique(versions))
category = [i[1][2] for i in df.mean]
subcategory_1 = [i[1][3] for i in df.mean]
subcategory_2 = [length(i[1]) > 3 ? i[1][4] : missing for i in df.mean]
subcategory_3 = [length(i[1]) > 4 ? i[1][5] : missing for i in df.mean]
unique_categories = sort(unique(category))
testname = [i[1][end] for i in df.mean]
unique_testnames = sort(unique(testname))

# Function to take the mean/std/minimum/median tuples and rename the columns
# to include their respective values
function supertuple(mean, std, minimum, median)
    # Append mean/std/minimum/median to the names of each tuple
    mean_names = [(Symbol ∘ string)(i, "_mean") for i in keys(mean)]
    std_names = [(Symbol ∘ string)(i, "_std") for i in keys(std)]
    minimum_names = [(Symbol ∘ string)(i, "_minimum") for i in keys(minimum)]
    median_names = [(Symbol ∘ string)(i, "_median") for i in keys(median)]

    # Make the NamedTuple names and values
    nt_names = tuple(vcat(mean_names, std_names, minimum_names, median_names)...)
    nt_values = vcat(
        NamedTuple{tuple(mean_names...)}(map(x -> mean[x], keys(mean))),
        NamedTuple{tuple(std_names...)}(map(x -> std[x], keys(std))),
        NamedTuple{tuple(minimum_names...)}(map(x -> minimum[x], keys(minimum))),
        NamedTuple{tuple(median_names...)}(map(x -> median[x], keys(median))),
    )

    return reduce(merge, nt_values)

    # # Create a new NamedTuple with all the names and values
    # return NamedTuple{tuple(vcat(mean_names, std_names, minimum_names, median_names)...)}(
    #     vcat(
    #         map(x -> mean[x], keys(mean)),
    #         map(x -> std[x], keys(std)),
    #         map(x -> minimum[x], keys(minimum)),
    #         map(x -> median[x], keys(median))
    #     )
    # )
end

st1 = supertuple(df.mean[1][2], df.std[1][2], df.minimum[1][2], df.median[1][2])
nt1 = merge((
        version=versions[1],
        category=category[1],
        subcategory_1=subcategory_1[1],
        subcategory_2=subcategory_2[1],
        subcategory_3=subcategory_3[1],
        testname=testname[1],
        date=df.date[1]
    ), st1)

# Make a vector of the type of nt1
results = map(eachindex(df.mean)) do i
    meanval = df.mean[i][2]
    stdval = df.std[i][2]
    minimumval = df.minimum[i][2]
    medianval = df.median[i][2]
    dateval = df.date[i]
    x = supertuple(meanval, stdval, minimumval, medianval)

    merge(
        (version=versions[i], category=category[i], subcategory_1=subcategory_1[i], subcategory_2=subcategory_2[i], subcategory_3=subcategory_3[i], testname=testname[i], date=dateval),
        x
    )
end

# Make a DataFrame from the results
collated = DataFrame(results)

# Get the major version number, format follows
# 1.9.0-DEV.1727
major_version(version) = split(version, "-")[1]
collated.major_version = major_version.(collated.version)

# Make a time column that is mean ± std
nothingtomissing(x::Nothing) = 0
nothingtomissing(x) = x

# Convert any columns that have nothing values to missing values
for col in names(collated)
    collated[!, col] = map(nothingtomissing, collated[!, col])
end

collated.time = map(x -> measurement(x.time_mean, nothingtomissing(x.time_std)), eachrow(collated))
collated.allocs = map(x -> measurement(x.allocs_mean, nothingtomissing(x.allocs_std)), eachrow(collated))
collated.memory = map(x -> measurement(x.memory_mean, nothingtomissing(x.memory_std)), eachrow(collated))
collated.gctime = map(x -> measurement(x.gctime_mean, nothingtomissing(x.gctime_std)), eachrow(collated))
collated.group = map(x -> join(skipmissing([x.category, x.subcategory_1, x.subcategory_2, x.subcategory_3, x.testname]), '-'), eachrow(collated))

# Save collated to a CSV
# TODO save this to a tempdir
CSV.write("collated.csv", collated)

# What's the most tested thing
test_counts = let
    g = groupby(collated, :group)
    c = combine(
        g,
        :testname => length => :n_tests,
        :version => length ∘ unique => :unique_versions,
        :time_mean => mean => :average_time,
        :allocs_mean => mean => :average_allocs,
        :memory_mean => mean => :average_memory,
        :gctime_mean => mean => :average_gctime,
    )

    sort(c, :n_tests, rev=true)
end

select(
    collated,
    [:version, :category, :subcategory_1, :subcategory_2, :subcategory_3, :testname, :date, :time, :gctime, :allocs, :memory]
)

# Pick a random testname
# # testname = rand(unique_testnames)
testname = test_counts.group[1]
# testname = :equal

# Filter the DataFrame to only include the testname
filtered = filter(row -> row.group == testname, collated)

# Plot date vs. time
scatter(
    filtered.date,
    filtered.time,
    title=testname,
    xlabel="Date",
    ylabel="Time (s)",
    # group=filtered.version,
    # title = "Time vs. Julia Version"
)

# Plot date vs. allocs
scatter(
    filtered.date,
    filtered.allocs,
    # yerr = filtered.time_std,
    title=testname,
    xlabel="Date",
    ylabel="Allocs",
    # title = "Time vs. Julia Version"
)

# Plot date vs. memory
scatter(
    filtered.date,
    filtered.memory_mean,
    # yerr = filtered.time_std,
    title=testname,
    xlabel="Julia Version",
    ylabel="Time (s)",
    # title = "Time vs. Julia Version"
)

# Plot date vs. gctime
scatter(
    filtered.date,
    filtered.gctime_mean,
    # yerr = filtered.time_std,
    title=testname,
    xlabel="Julia Version",
    ylabel="Mean Time (s)",
    # title = "Time vs. Julia Version"
)

# Plot minimum time
scatter(
    filtered.date,
    filtered.time_minimum
)

res = combine(groupby(collated, :group)) do subgroup
    sort!(subgroup, :date)

    # Get the level change from previous day
    subgroup.change = subgroup.time ./ vcat(missing, subgroup.time[1:end-1]) .- 1
    select(subgroup, [:group, :date, :time, :change])
end

# Histogram of changes
histogram(mean.(res.change))
