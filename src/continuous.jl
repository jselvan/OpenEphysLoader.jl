# code for loading .continuous files
### Constants ###
const CONT_REC_TIME_BITTYPE = Int64
const CONT_REC_N_SAMP = 1024
const CONT_REC_N_SAMP_BITTYPE = UInt16
const CONT_REC_REC_NO_BITTYPE = UInt16
const CONT_REC_SAMP_BITTYPE = Int16
const CONT_REC_BYTES_PER_SAMP = sizeof(CONT_REC_SAMP_BITTYPE)
const CONT_REC_END_MARKER = UInt8[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
                                  0x07, 0x08, 0xff]
const CONT_REC_HEAD_SIZE = mapreduce(sizeof, +, [CONT_REC_TIME_BITTYPE,
                             CONT_REC_N_SAMP_BITTYPE, CONT_REC_REC_NO_BITTYPE])
const CONT_REC_BODY_SIZE = CONT_REC_N_SAMP * sizeof(CONT_REC_SAMP_BITTYPE)
const CONT_REC_TAIL_SIZE = sizeof(CONT_REC_END_MARKER)
const CONT_REC_BLOCK_SIZE = CONT_REC_HEAD_SIZE + CONT_REC_BODY_SIZE + CONT_REC_TAIL_SIZE

### Types ###
"Type to buffer continuous file contents"
abstract BlockBuffer

"Represents the header of each data block"
type BlockHeader <: BlockBuffer
    timestamp::CONT_REC_TIME_BITTYPE
    nsample::CONT_REC_N_SAMP_BITTYPE
    recordingnumber::CONT_REC_REC_NO_BITTYPE
end
BlockHeader() = BlockHeader(0, 0, 0)

"Represents the entirety of a data block"
type DataBlock <: BlockBuffer
    head::BlockHeader
    body::Vector{UInt8}
    data::Vector{CONT_REC_SAMP_BITTYPE}
    tail::Vector{UInt8}
end
function DataBlock()
    head = BlockHeader()
    body = Vector{UInt8}(CONT_REC_BODY_SIZE)
    data = Vector{CONT_REC_SAMP_BITTYPE}(CONT_REC_N_SAMP)
    tail =  Vector{UInt8}(CONT_REC_TAIL_SIZE)
    DataBlock(head, body, data, tail)
end

"""
    ContinuousFile(io::IOStream)
Type for an open continuous file.

# Fields

**`io`** `IOStream` object.

**`nsample`** number of samples in a file.

**`nblock`** number of data blocks in a file.

**`header`** [`OriginalHeader`](@ref) of the current file.
"""
immutable ContinuousFile{T<:Integer, S<:Integer, H<:OriginalHeader}
    "IOStream for open continuous file"
    io::IOStream
    "Number of samples in file"
    nsample::T
    "Number of data blocks in file"
    nblock::S
    "File header"
    header::H
end
function ContinuousFile(io::IOStream)
    header = OriginalHeader(io) # Read header
    nblock = count_blocks(io)
    nsample = count_data(nblock)
    return ContinuousFile(io, nsample, nblock, header)
end

"""
Abstract array for file-backed open ephys data.

All subtypes support an array interface, and have the following fields:

# Fields

**`contfile`** [`ContinuousFile`](@ref) for the current file.

**`block`** buffer object for the data blocks in the file.

**`blockno`** the current block being access in the file.

**`check`** `Bool` to check each data block's validity.
"""
abstract OEContArray{T, C<:ContinuousFile} <: AbstractArray{T, 1}
### Stuff for code generation ###
sampletype = Real
timetype = Real
rectype = Integer
jointtype = Tuple{sampletype, timetype, rectype}
arraytypes = ((:SampleArray, sampletype, DataBlock, Float64),
              (:TimeArray, timetype, BlockHeader, Float64),
              (:RecNoArray, rectype, BlockHeader, Int),
              (:JointArray, jointtype, DataBlock, Tuple{Float64, Float64, Int}))
### Generate array datatypes ###
for (typename, typeparam, buffertype, defaulttype) = arraytypes
    @eval begin
        type $(typename){T<:$(typeparam), C<:ContinuousFile} <: OEContArray{T, C}
            contfile::C
            block::$(buffertype)
            blockno::UInt
            check::Bool
        end
        function $(typename){T, C<:ContinuousFile}(
            ::Type{T}, contfile::C, check::Bool = true)
            if check
                check_filesize(contfile.io)
            end
            block = $(buffertype)()
            return $(typename){T, C}(contfile, block, 0, check)
        end
        function $(typename){T}(::Type{T}, io::IOStream, check::Bool = true)
            return $(typename)(T, ContinuousFile(io))
        end
        $(typename)(io::IOStream, check::Bool=true) = $(typename)($(defaulttype), io, check)
    end
end

const arrayargs = "(type::Type{T}, io::IOStream, [check::Bool])"
const arraypreamble = "Subtype of [`OEContArray`](@ref) to provide file backed access to OpenEphys"
@doc """
    SampleArray$arrayargs
$arraypreamble sample values. If `type` is a floating
point type, then the sample value will be converted to voltage (in uV). Otherwise,
the sample values will remain the raw ADC integer readings.
""" SampleArray
@doc """
    TimeArray$arrayargs
$arraypreamble time stamps. If `type` is a floating
point type, then the time stamps will be converted to seconds. Otherwise,
the time stamp will be the sample number.
""" TimeArray
@doc """
    RecNoArray$arrayargs
$arraypreamble numbers.
""" RecNoArray
@doc """
    JointArray$arrayargs
$arraypreamble data. Returns a tuple of type `type`, whose
values represent `(samplevalue, timestamp, recordingnumber)`. For a description of
each, see `SampleArray`, `TimeArray`, and `RecNoArray`, respectively.
""" JointArray
### Array interface ###
length(A::OEContArray) = A.contfile.nsample

size(A::OEContArray) = (length(A), 1)

linearindexing{T<:OEContArray}(::Type{T}) = Base.LinearFast()

setindex!(::OEContArray, ::Int) = throw(ReadOnlyMemoryError())

function getindex(A::OEContArray, i::Integer)
    prepare_block(A, i)
    relidx = sampno_to_offset(i)
    data = block_data(A, relidx)
    return convert_data(A, data)
end

### Array helper functions ###
"Load data block if necessary"
function prepare_block(A::OEContArray, i::Integer)
    blockno = sampno_to_block(i)
    if blockno != A.blockno
        seek_to_block(A.contfile.io, blockno)
        goodread = read_into!(A.contfile.io, A.block, A.check)
        goodread || throw(CorruptedException)
        A.blockno = blockno
    end
end

"Move io to data block"
function seek_to_block(io::IOStream, blockno::Integer)
    blockpos = block_start_pos(blockno)
    if blockpos != position(io)
        seek(io, blockpos)
    end
end

### location functions ###
sampno_to_block(sampno::Integer) = fld(sampno - 1, CONT_REC_N_SAMP) + 1

sampno_to_offset(sampno::Integer) = mod(sampno - 1, CONT_REC_N_SAMP) + 1

block_start_pos(blockno::Integer) = (blockno - 1) * CONT_REC_BLOCK_SIZE + HEADER_N_BYTES

### File access and conversion ###
"Read file data block into data block buffer"
function read_into!(io::IOStream, block::DataBlock, check::Bool = true)
    goodread = read_into!(io, block.head)
    goodread || return goodread
    ## Read the body
    nbytes = readbytes!(io, block.body, CONT_REC_BODY_SIZE)
    goodread = nbytes == CONT_REC_BODY_SIZE
    goodread || return goodread
    if check
        goodread = verify_tail!(io, block.tail)
    else
        skip(io, CONT_REC_TAIL_SIZE)
    end
    goodread && convert_block!(block)
    return goodread
end
"Read block header into header buffer"
function read_into!(io::IOStream, head::BlockHeader)
    goodread = true
    try
        head.timestamp = read(io, CONT_REC_TIME_BITTYPE)
        head.nsample = read(io, CONT_REC_N_SAMP_BITTYPE)
        goodread = head.nsample == CONT_REC_N_SAMP
        if goodread
            head.recordingnumber = read(io, CONT_REC_REC_NO_BITTYPE)
        end
    catch exception
        if isa(exception, EOFError)
            goodread = false
        else
            rethrow(exception)
        end
    end
    return goodread
end
read_into!(io::IOStream, head::BlockHeader, ::Bool) = read_into!(io, head)

"Convert the wacky data format in OpenEphys continuous files"
function convert_block!(block::DataBlock)
    contents = reinterpret(CONT_REC_SAMP_BITTYPE, block.body) # readbuff is UInt8
    # Correct for big endianness of this data block
    for idx in eachindex(contents)
        @inbounds contents[idx] = ntoh(contents[idx])
    end
    copy!(block.data, contents)
end

### Methods to access data in buffer ###
block_data(A::SampleArray, rel_idx::Integer) = A.block.data[rel_idx]
block_data(A::TimeArray, rel_idx::Integer) = A.block.timestamp + rel_idx - 1
block_data(A::RecNoArray, ::Integer) = A.block.recordingnumber
function block_data(A::JointArray, rel_idx::Integer)
    sample = A.block.data[rel_idx]
    timestamp = A.block.head.timestamp + rel_idx - 1
    recno = A.block.head.recordingnumber
    return sample, timestamp, recno
end

### Methods to convert raw values into desired ones ##
convert_data{A<:OEContArray}(OE::A, data) = convert_data(A, OE.contfile.header, data)
function convert_data{T<:AbstractFloat, C}(::Type{SampleArray{T, C}},
                                              H::OriginalHeader, data::Integer)
    return convert(T, data * H.bitvolts)
end
function convert_data{T<:Integer, C}(::Type{SampleArray{T, C}},
                                              ::OriginalHeader, data::Integer)
    return convert(T, data)
end
function convert_data{T<:AbstractFloat, C}(::Type{TimeArray{T, C}},
                                              H::OriginalHeader, data::Integer)
    return convert(T, (data - 1) / H.samplerate) # First sample is at time zero
end
function convert_data{T<:Integer, C}(::Type{TimeArray{T, C}},
                                              ::OriginalHeader, data::Integer)
    return convert(T, data)
end
function convert_data{T, C}(::Type{RecNoArray{T, C}}, ::OriginalHeader, data::Integer)
    return convert(T, data)
end
function convert_data{S<:sampletype,T<:timetype,R<:rectype,C}(
    ::Type{JointArray{Tuple{S,T,R},C}}, H::OriginalHeader, data::Tuple)
    samp = convert_data(SampleArray{S, C}, H, data[1])
    timestamp = convert_data(TimeArray{T, C}, H, data[2])
    recno = convert_data(RecNoArray{R, C}, H, data[3])
    return samp, timestamp, recno
end

### Verification methods ###
function verify_tail!(io::IOStream, tail::Vector{UInt8})
    nbytes = readbytes!(io, tail, CONT_REC_TAIL_SIZE)
    goodread = nbytes == CONT_REC_TAIL_SIZE && tail == CONT_REC_END_MARKER
    return goodread
end

function check_filesize(file::IOStream)
    rem(filesize(file) - HEADER_N_BYTES, CONT_REC_BLOCK_SIZE) == 0 || throw(CorruptedError())
end

### Utility methods ###
function count_blocks(file::IOStream)
    fsize = stat(file).size
    return div(fsize - HEADER_N_BYTES, CONT_REC_BLOCK_SIZE)
end

count_data(numblocks::Integer) = numblocks * CONT_REC_N_SAMP
count_data(file::IOStream) = count_data(count_blocks(file))
