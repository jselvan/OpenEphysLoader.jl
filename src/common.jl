# common types
abstract OEData
abstract KwikData <: OEData
type CorruptionError <: Exception end
type UnreadableError <: Exception msg::AbstractString end

showerror(io::IO, exc::UnreadableError) = print(io, exc.msg)
