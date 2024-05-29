"""
    Layers(layers::Vector{Layer})

Algebraic object encoding a list of [`AlgebraOfGraphics.Layer`](@ref) objects.
`Layers` objects can be added or multiplied, yielding a novel `Layers` object.
"""
struct Layers <: AbstractAlgebraic
    layers::Vector{Layer}
end

Base.convert(::Type{Layers}, l::Layer) = Layers([l])

Base.getindex(layers::Layers, i::Int) = layers.layers[i]
Base.length(layers::Layers) = length(layers.layers)
Base.eltype(::Type{Layers}) = Layer
Base.iterate(layers::Layers, args...) = iterate(layers.layers, args...)

function Base.:+(a::AbstractAlgebraic, a′::AbstractAlgebraic)
    layers::Layers, layers′::Layers = a, a′
    return Layers(vcat(layers.layers, layers′.layers))
end

function Base.:*(a::AbstractAlgebraic, a′::AbstractAlgebraic)
    layers::Layers, layers′::Layers = a, a′
    return Layers([layer * layer′ for layer in layers for layer′ in layers′])
end

"""
    ProcessedLayers(layers::Vector{ProcessedLayer})

Object encoding a list of [`AlgebraOfGraphics.ProcessedLayer`](@ref) objects.
`ProcessedLayers` objects are the output of the processing pipeline and can be
drawn without further processing.
"""
struct ProcessedLayers <: AbstractDrawable
    layers::Vector{ProcessedLayer}
end

function ProcessedLayers(a::AbstractAlgebraic)
    layers::Layers = a
    return ProcessedLayers(map(process, layers))
end

ProcessedLayers(p::ProcessedLayer) = ProcessedLayers([p])
ProcessedLayers(p::ProcessedLayers) = p

function compute_processedlayers_grid(processedlayers, categoricalscales)
    indices = CartesianIndices(compute_grid_positions(categoricalscales))
    pls_grid = map(_ -> ProcessedLayer[], indices)
    for processedlayer in processedlayers
        append_processedlayers!(pls_grid, processedlayer, categoricalscales)
    end
    return pls_grid
end

function compute_entries_continuousscales(pls_grid, categoricalscales)
    # Here processed layers in `pls_grid` are "sliced",
    # the categorical scales have been applied, but not
    # the continuous scales

    rescaled_pls_grid = map(_ -> ProcessedLayer[], pls_grid)
    continuousscales_grid = map(_ -> MultiAesScaleDict{ContinuousScale}(), pls_grid)

    for idx in eachindex(pls_grid), pl in pls_grid[idx]
        # Apply continuous transformations
        positional = map(contextfree_rescale, pl.positional)
        named = map(contextfree_rescale, pl.named)
        plottype = Makie.plottype(pl.plottype, positional...)

        aes_mapping = aesthetic_mapping(plottype, pl.attributes)

        # Compute continuous scales with correct plottype, to figure out role of color
        continuousscales = AlgebraOfGraphics.continuousscales(ProcessedLayer(pl; plottype))

        for (key, scale) in pairs(continuousscales)
            aes = aes_mapping[key]
            scaledict = continuousscales_grid[idx]
            if !haskey(scaledict, aes)
                insert!(scaledict, aes, eltype(scaledict)())
            end
            dict = scaledict[aes]
            scale_id = get(pl.scale_mapping, key, nothing)
            if !haskey(dict, scale_id)
                insert!(dict, scale_id, scale)
            else
                dict[scale_id] = mergescales(dict[scale_id], scale)
            end
        end

        # Compute `ProcessedLayer` with rescaled columns
        push!(rescaled_pls_grid[idx], ProcessedLayer(pl; plottype, positional, named))
    end

    function merge_nested_scaledict!(dict1, dict2)
        for (key, subdict) in pairs(dict2)
            if !haskey(dict1, key)
                insert!(dict1, key, subdict)
            else
                mergewith!(mergescales, dict1[key], subdict)
            end
        end
        return dict1
    end

    # Compute merged continuous scales, as it may be needed to use global extrema
    merged_continuousscales = reduce(merge_nested_scaledict!, continuousscales_grid, init=MultiAesScaleDict{ContinuousScale}())

    to_entry = function (pl)
        attrs = compute_attributes(pl, categoricalscales, continuousscales_grid, merged_continuousscales)
        return Entry(pl.plottype, pl.positional, attrs)
    end
    entries_grid = map(pls -> map(to_entry, pls), rescaled_pls_grid)

    return entries_grid, continuousscales_grid, merged_continuousscales
end

function compute_palettes(palettes)
    layout = Dictionary((layout=wrap,))
    theme_palettes = map(to_value, Dictionary(Makie.current_default_theme()[:palette]))
    user_palettes = Dictionary(palettes)
    return foldl(merge!, (layout, theme_palettes, user_palettes), init=NamedArguments())
end

function compute_axes_grid(fig, d::AbstractDrawable;
                           axis=NamedTuple(), palettes=NamedTuple())

    axes_grid = compute_axes_grid(d; axis, palettes)
    sz = size(axes_grid)
    if sz != (1, 1) && fig isa Axis
        msg = "You can only pass an `Axis` to `draw!` if the calculated layout only contains one element. Elements: $(sz)"
        throw(ArgumentError(msg))
    end

    return map(ae -> AxisEntries(ae, fig), axes_grid)
end

function hardcoded_visual_scale(key)
    key === :layout ? AesLayout :
    key === :row ? AesRow :
    key === :col ? AesCol :
    key === :group ? AesGroup :
    nothing
end

const AestheticMapping = Dictionary{Union{Int,Symbol},Type{<:Aesthetic}}

function hardcoded_or_mapped_aes(processedlayer, key::Union{Int,Symbol}, aes_mapping::AestheticMapping)
    hardcoded = hardcoded_visual_scale(key)
    hardcoded !== nothing && return hardcoded
    if !haskey(aes_mapping, key)
        throw(ArgumentError("ProcessedLayer with plot type $(processedlayer.plottype) did not have $key in its AestheticMapping. The mapping was $aes_mapping"))
    end
    return aes_mapping[key]
end

function compute_axes_grid(d::AbstractDrawable;
                           axis=NamedTuple(), palettes=NamedTuple())
    palettes = compute_palettes(palettes)

    processedlayers = ProcessedLayers(d).layers

    categoricalscales = MultiAesScaleDict{CategoricalScale}()
    
    for processedlayer in processedlayers
        catscales = AlgebraOfGraphics.categoricalscales(processedlayer, palettes)
        aes_mapping = aesthetic_mapping(processedlayer)

        for (key, scale) in pairs(catscales)
            scale_id = get(processedlayer.scale_mapping, key, nothing)
            aes = hardcoded_or_mapped_aes(processedlayer, key, aes_mapping)
            if !haskey(categoricalscales, aes)
                insert!(categoricalscales, aes, eltype(categoricalscales)())
            end
            scaledict = categoricalscales[aes]
            if !haskey(scaledict, scale_id)
                insert!(scaledict, scale_id, scale)
            else
                scaledict[scale_id] = mergescales(scaledict[scale_id], scale)
            end
        end
    end
    # fit categorical scales (compute plot values using all data values)
    for scaledict in values(categoricalscales)
        map!(fitscale, scaledict, scaledict)
    end

    pls_grid = compute_processedlayers_grid(processedlayers, categoricalscales)
    entries_grid, continuousscales_grid, merged_continuousscales =
        compute_entries_continuousscales(pls_grid, categoricalscales)

    indices = CartesianIndices(pls_grid)
    axes_grid = map(indices) do c
        return AxisSpecEntries(
            AxisSpec(c, axis),
            entries_grid[c],
            categoricalscales,
            continuousscales_grid[c],
            pls_grid[c],
        )
    end

    # Axis labels and ticks
    for ae in axes_grid
        ndims = isaxis2d(ae) ? 2 : 3
        aesthetics = [AesX, AesY, AesZ]
        for (aes, var) in zip(aesthetics[1:ndims], (:x, :y, :z)[1:ndims])
            if haskey(ae.categoricalscales, aes)
                scales = ae.categoricalscales[aes]
                if length(keys(scales)) != 1 || only(keys(scales)) !== nothing
                    error("There should only be one $aes, found keys $(keys(scales))")
                end
                scale = scales[nothing]
            elseif haskey(ae.continuousscales, aes)
                scales = ae.continuousscales[aes]
                if length(keys(scales)) != 1 || only(keys(scales)) !== nothing
                    error("There should only be one $aes, found keys $(keys(scales))")
                end
                scale = scales[nothing]
            else
                continue
            end
            label = getlabel(scale)
            # Use global scales for ticks for now
            # TODO: requires a nicer mechanism that takes into account axis linking
            (scale isa ContinuousScale) && (scale = merged_continuousscales[aes][nothing])
            for (k, v) in pairs((label=to_string(label), ticks=ticks(scale)))
                keyword = Symbol(var, k)
                # Only set attribute if it was not present beforehand
                get!(ae.axis.attributes, keyword, v)
            end
        end
    end

    return axes_grid
end
