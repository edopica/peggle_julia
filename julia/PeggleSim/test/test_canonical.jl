using Test
using Printf
using PeggleSim
import JSON

@testset "Canonical JSON" begin
    @testset "numeric formatting matches canonical_json.lua" begin
        # Expected strings below were produced by tools/canonical_json.lua
        # under LuaJIT 2.1 on this machine; they are the byte-for-byte target.
        @test canonical_json(1.0) == "1"
        @test canonical_json(0.0) == "0"
        @test canonical_json(-0.0) == "-0"
        @test canonical_json(0.1) == "0.10000000000000001"
        @test canonical_json(1 / 3) == "0.33333333333333331"
        @test canonical_json(1e300) == "1.0000000000000001e+300"
        @test canonical_json(-1e300) == "-1.0000000000000001e+300"
        @test canonical_json(5e-324) == "4.9406564584124654e-324"
        @test canonical_json(2.0^53) == "9007199254740992"
        @test canonical_json(2.0^53 + 2.0) == "9007199254740994"
        @test canonical_json(2.0^53 - 1.0) == "9007199254740991"
        @test canonical_json(1e15) == "1000000000000000"
        @test canonical_json(1e16) == "10000000000000000"
        @test canonical_json(1e17) == "1e+17"
        @test canonical_json(2.5) == "2.5"
        @test canonical_json(-3.0) == "-3"
        @test canonical_json(2.2250738585072014e-308) == "2.2250738585072014e-308"
        @test canonical_json(1.7976931348623157e308) == "1.7976931348623157e+308"
        @test canonical_json(123) == "123"
        @test canonical_json(-7) == "-7"
        @test canonical_json(-0.0) != canonical_json(0.0)
    end

    @testset "integral vs nonintegral rule" begin
        @test canonical_json(2.0) == "2"
        @test canonical_json(2.5) == "2.5"
        @test canonical_json(1.0e0) == "1"
        @test canonical_json(-1.5) == "-1.5"
        # At or above 2^53 the integer shortcut stops being used.
        @test canonical_json(2.0^53) == @sprintf("%.17g", 2.0^53)
        @test canonical_json(2.0^53 + 2.0) == @sprintf("%.17g", 2.0^53 + 2.0)
    end

    @testset "empty containers are explicit" begin
        @test canonical_json(Any[]) == "[]"
        @test canonical_json(Dict{String,Any}()) == "{}"
        @test canonical_json(CanonicalArray()) == "[]"
        @test canonical_json(CanonicalObject()) == "{}"
        @test canonical_json(CanonicalArray([1, 2])) == "[1,2]"
        @test canonical_json(CanonicalObject(Dict{String,Any}("a" => 1))) == "{\"a\":1}"
        @test canonical_json(Any[Any[], Dict{String,Any}()]) == "[[],{}]"
    end

    @testset "sorted object keys" begin
        d = Dict{String,Any}(
            "b" => 1, "a" => 2, "aa" => 3, "A" => 4, "10" => 5, "2" => 6)
        @test canonical_json(d) ==
              "{\"10\":5,\"2\":6,\"A\":4,\"a\":2,\"aa\":3,\"b\":1}"
        nt = (z = [1, 2], a = "x")
        @test canonical_json(nt) == "{\"a\":\"x\",\"z\":[1,2]}"
    end

    @testset "array order and nesting" begin
        @test canonical_json(Any[1, 2.5, "x", true,
                                 Dict{String,Any}("b" => 1, "a" => 2)]) ==
              "[1,2.5,\"x\",true,{\"a\":2,\"b\":1}]"
        @test canonical_json((1, 2.5, false)) == "[1,2.5,false]"
    end

    @testset "string escaping" begin
        @test canonical_json(["a\"b\\c", "tab\tnl\n", "\x01\x1f", "plain"]) ==
              "[\"a\\\"b\\\\c\",\"tab\\tnl\\n\",\"\\u0001\\u001f\",\"plain\"]"
        @test canonical_json("\b\f\r") == "\"\\b\\f\\r\""
    end

    @testset "NaN and infinity rejected" begin
        @test_throws ArgumentError canonical_json(NaN)
        @test_throws ArgumentError canonical_json(Inf)
        @test_throws ArgumentError canonical_json(-Inf)
        @test_throws ArgumentError canonical_json(Any[1.0, NaN])
        @test_throws ArgumentError canonical_json(Dict{String,Any}("x" => Inf))
        @test_throws ArgumentError canonical_json(Float32(NaN))
    end

    @testset "bit-exact parse round trip from %.17g text" begin
        values = Float64[
            0.0, 1.0, 0.1, 1 / 3, 2.5, -3.0, 1e300, -1e300, 5e-324,
            2.0^53, 2.0^53 + 2.0, 2.0^53 - 1.0, 1e15, 1e16, 1e17,
            2.2250738585072014e-308, 1.7976931348623157e308,
            6.283185307179586, 123456789.123456789, 1.0000000000000002,
        ]
        for x in values
            text = @sprintf("%.17g", x)
            parsed = JSON.parse(text)
            @test Float64(parsed) isa Float64
            @test reinterpret(UInt64, Float64(parsed)) == reinterpret(UInt64, x)
        end
    end

    @testset "float_bits_hex" begin
        @test float_bits_hex(1.0) == "0x3ff0000000000000"
        @test float_bits_hex(-0.0) == "0x8000000000000000"
        @test float_bits_hex(0.0) == "0x0000000000000000"
        @test float_bits_hex(0.1) == "0x3fb999999999999a"
        @test float_bits_hex(2.0^53) == "0x4340000000000000"
    end

    @testset "sha256_hex" begin
        @test sha256_hex("") ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        @test sha256_hex("abc") ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        @test sha256_hex(Dict{String,Any}("a" => 1)) == sha256_hex("{\"a\":1}")
        @test sha256_hex(UInt8[0x61, 0x62, 0x63]) == sha256_hex("abc")
    end

    @testset "jsonio accessors" begin
        text = "{\"n\":3,\"f\":2.5,\"b\":true,\"s\":\"x\",\"a\":[1,2],\"o\":{\"k\":1}}"
        d = JSON.parse(text)
        @test as_int(d["n"]) == 3
        @test as_int(3.0) == 3
        @test as_f64(d["f"]) == 2.5
        @test as_f64(3) == 3.0
        @test as_bool(d["b"]) === true
        @test as_string(d["s"]) == "x"
        @test as_array(d["a"]) == Any[1, 2]
        @test as_object(d["o"])["k"] == 1
        @test_throws ArgumentError as_int(2.5)
        @test_throws ArgumentError as_int(true)
        @test_throws ArgumentError as_bool(1)
        @test_throws ArgumentError as_string(1)
        @test_throws ArgumentError as_array(1)
        @test_throws ArgumentError as_object(1)

        @test canonical_type_order() == (:blue, :green, :purple, :red)
        @test canonical_type_order(:red) == 4
        @test canonical_type_order([:red, :blue, :purple]) ==
              [:blue, :purple, :red]
        @test_throws ArgumentError canonical_type_order(:orange)
    end

    @testset "full document sample matches Lua encoder" begin
        doc = Dict{String,Any}(
            "format" => "sample",
            "count" => 2,
            "items" => Any[
                Dict{String,Any}("id" => 1, "value" => -0.0),
                Dict{String,Any}("id" => 2, "value" => 1e300),
            ],
            "empty" => CanonicalArray(),
            "map" => CanonicalObject(),
        )
        expected = "{\"count\":2,\"empty\":[],\"format\":\"sample\"," *
                   "\"items\":[{\"id\":1,\"value\":-0}," *
                   "{\"id\":2,\"value\":1.0000000000000001e+300}],\"map\":{}}"
        @test canonical_json(doc) == expected
    end
end
