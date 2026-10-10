-- Pure-LuaJIT SHA-256 (FIPS 180-4).
--
-- API:
--   local SHA = require("tools.sha256")
--   SHA.sha256_hex(data)   -- lowercase 64-character hex digest of `data`
--
-- `data` is a byte string. Only the LuaJIT `bit` library is used (no FFI, no
-- external hashing), so the module is safe to load in plain `luajit` and in
-- LÖVE. It pins artifact bytes for the WP-D math comparison.

local bit = require("bit")

local M = {}

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- SHA-256 of a byte string, as 64 lowercase hex characters.
function M.sha256_hex(message)
    local band, bxor, bnot, ror, rshift = bit.band, bit.bxor, bit.bnot, bit.ror, bit.rshift
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local len = #message
    local bitlen = len * 8
    local zeros = (56 - ((len + 1) % 64)) % 64
    local hi = math.floor(bitlen / 4294967296) % 4294967296
    local lo = bitlen % 4294967296
    local msg = message .. "\128" .. string.rep("\0", zeros)
        .. string.char(
            math.floor(hi / 16777216) % 256, math.floor(hi / 65536) % 256,
            math.floor(hi / 256) % 256, hi % 256,
            math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256,
            math.floor(lo / 256) % 256, lo % 256)

    local w = {}
    local blocks = #msg / 64
    for block = 0, blocks - 1 do
        local base = block * 64
        for j = 0, 15 do
            local o = base + j * 4 + 1
            local b0, b1, b2, b3 = msg:byte(o, o + 3)
            w[j] = b0 * 16777216 + b1 * 65536 + b2 * 256 + b3
        end
        for j = 16, 63 do
            local x, y = w[j - 15], w[j - 2]
            local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
            local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % 4294967296
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for j = 0, 63 do
            local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (h + s1 + ch + K[j + 1] + w[j]) % 4294967296
            local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = (s0 + maj) % 4294967296
            h = g
            g = f
            f = e
            e = (d + temp1) % 4294967296
            d = c
            c = b
            b = a
            a = (temp1 + temp2) % 4294967296
        end
        h0 = (h0 + a) % 4294967296
        h1 = (h1 + b) % 4294967296
        h2 = (h2 + c) % 4294967296
        h3 = (h3 + d) % 4294967296
        h4 = (h4 + e) % 4294967296
        h5 = (h5 + f) % 4294967296
        h6 = (h6 + g) % 4294967296
        h7 = (h7 + h) % 4294967296
    end

    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        h0, h1, h2, h3, h4, h5, h6, h7)
end

return M
