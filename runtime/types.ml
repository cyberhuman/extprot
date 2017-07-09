
type low_level_type =
    Vint
  | Bits8
  | Bits32
  | Bits64_long
  | Bits64_float
  | Enum
  | Tuple
  | Bytes
  | Htuple
  | Assoc
  | Invalid_ll_type

let string_of_low_level_type = function
    Vint -> "Vint"
  | Bits8 -> "Bits8"
  | Bits32 -> "Bits32"
  | Bits64_long -> "Bits64_long"
  | Bits64_float -> "Bits64_float"
  | Enum -> "Enum"
  | Bytes -> "Bytes"
  | Tuple -> "Tuple"
  | Htuple -> "Htuple"
  | Assoc -> "Assoc"
  | Invalid_ll_type -> failwith "string_of_low_level_type: Invalid_ll_type"

type repr_wire_type =
  | Varint
  | Int8
  | Int32
  | Int64
  | Float64
  | Bytes
  | Sum of (string * repr_wire_type list) list
  | Record of (string * repr_wire_type) list
  | Tuple of repr_wire_type list
  | Array of repr_wire_type
  | Sum_record of (string * (string * repr_wire_type) list) list
