-- train: a small network over the records of `record` (REC lines), predicting what a move brought (HP dealt minus
-- HP taken over the window, in hundreds) from the situation and the move — the "brain" XOI weighs with its own
-- score (scripts/base/game/smart_ai.lua, brain_kit). Inputs 58 -> hidden H (ReLU) -> 1, plain SGD; LuaJIT does
-- about 150,000 samples a second for H = 48, so a few million records train in minutes an epoch.
--   The records: files xoi/data_1.txt, xoi/data_2.txt, ... in the pack (hoc-sau.bat packs the gathered REC lines so,
--   each file under 4 MB — a script reads a resource up to 4 MiB), or bench modules <data>_1, <data>_2, ... /
--   <data> returning {text = "..."} (data = "rec_data").
--   hidden (48), epochs (8), rate (0.01, times `decay` (0.6) each epoch), holdout (every n-th record kept for the
--   test: 5), stride (1: every record; k keeps every k-th, for a quicker look at a big set), seed, weights (false:
--   no XOI_BRAIN lines, the figures only). A record takes about 500 bytes of memory: six million, 3 GB.
-- Prints TRAIN (counts), BASE (the mean alone, and how the player's own score correlates with the outcome),
-- LINEAR and NET<H> a line an epoch (train mse, test mse, test correlation), then the network as XOI_BRAIN lines
-- (the text of xoi/brain.txt: hoc-sau.bat keeps them).
local job = {}

local function generator(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 48271) % 2147483647
        return s / 2147483647
    end
end

-- Standardized inputs are clipped at ±6 (as brain_kit.predict clips them): a rare far-out value does not throw
-- the gradient.
local CLIP = 6

local function correlation(a, b, count)
    if count < 2 then return 0 end
    local ma, mb = 0, 0
    for i = 1, count do ma = ma + a[i]; mb = mb + b[i] end
    ma, mb = ma / count, mb / count
    local sab, saa, sbb = 0, 0, 0
    for i = 1, count do
        local da, db = a[i] - ma, b[i] - mb
        sab = sab + da * db; saa = saa + da * da; sbb = sbb + db * db
    end
    if saa <= 0 or sbb <= 0 then return 0 end
    return sab / math.sqrt(saa * sbb)
end

function job.run(config)
    local name = config.data or "rec_data"
    -- The records go into tables as they are read (X[r]: the n numbers of record r, Y[r]: its outcome), one file
    -- at a time, so that a few million records take their numbers' room and no more.
    local n = nil
    local X, Y = {}, {}
    local count, dropped, files, bytes, seen = 0, 0, 0, 0, 0
    local stride = config.stride or 1
    local tokens = {}
    local function take(text)
        files, bytes = files + 1, bytes + #text
        for line in text:gmatch("[^\r\n]+") do
            if line:sub(1, 4) == "REC " then
                seen = seen + 1
                if seen % stride == 0 then
                    local k = 0
                    for token in line:gmatch("%S+") do
                        k = k + 1
                        tokens[k] = token
                    end
                    -- tokens[1] = "REC", [2] slot, [3] dealt, [4] taken, [5..] features
                    local dealt, taken = tonumber(tokens[3]), tonumber(tokens[4])
                    local m = k - 4
                    if n == nil and m > 0 then n = m end
                    local row = nil
                    if dealt and taken and m == n then
                        row = {}
                        for i = 1, n do
                            local v = tonumber(tokens[4 + i])
                            if not v then row = nil; break end
                            row[i] = v
                        end
                    end
                    if row then
                        count = count + 1
                        X[count] = row
                        local y = (dealt - taken) / 100
                        if y > 2 then y = 2 elseif y < -2 then y = -2 end
                        Y[count] = y
                    else
                        dropped = dropped + 1
                    end
                end
            end
        end
    end
    local i = 1
    while true do
        local ok, text = pcall(engine.read_resource, "xoi/data_" .. i .. ".txt")
        if not ok or type(text) ~= "string" then break end
        take(text)
        i = i + 1
    end
    if files == 0 then
        local ok, one = pcall(require, "bench/" .. name)
        if ok and type(one) == "table" and one.text then take(one.text) end
        i = 1
        while true do
            local ok2, part = pcall(require, "bench/" .. name .. "_" .. i)
            if not ok2 or type(part) ~= "table" or not part.text then break end
            take(part.text)
            i = i + 1
        end
    end
    assert(files > 0, "no records: xoi/data_1.txt in the pack, or bench module " .. name)
    engine.log(string.format("records read from %d file(s), %.1f MB: %d records%s%s", files, bytes / 1048576, count,
        stride > 1 and string.format(" (every %dth of %d)", stride, seen) or "",
        dropped > 0 and string.format(" (%d lines dropped: not a whole record)", dropped) or ""))
    assert(n and count > 100, "too few records")
    -- Every holdout-th record is the test's; the rest train.
    local holdout = config.holdout or 5
    local train, test = {}, {}
    for r = 1, count do
        if r % holdout == 0 then test[#test + 1] = r else train[#train + 1] = r end
    end
    -- Standardized in place over the training records' mean and spread, clipped.
    local mean, sd = {}, {}
    for f = 1, n do mean[f] = 0; sd[f] = 0 end
    for _, r in ipairs(train) do
        local x = X[r]
        for f = 1, n do mean[f] = mean[f] + x[f] end
    end
    for f = 1, n do mean[f] = mean[f] / #train end
    for _, r in ipairs(train) do
        local x = X[r]
        for f = 1, n do local d = x[f] - mean[f]; sd[f] = sd[f] + d * d end
    end
    for f = 1, n do sd[f] = math.sqrt(sd[f] / #train); if sd[f] < 1e-6 then sd[f] = 1 end end
    for r = 1, count do
        local x = X[r]
        for f = 1, n do
            local v = (x[f] - mean[f]) / sd[f]
            if v > CLIP then v = CLIP elseif v < -CLIP then v = -CLIP end
            x[f] = v
        end
    end
    engine.log(string.format("TRAIN %d records (%d train, %d test), %d features", count, #train, #test, n))
    -- Baselines: the mean alone, and the player's own score ('score' is the 2nd of the last 17 numbers: n - 15).
    local si = config.score_index or (n - 15)
    local ymean = 0
    for _, r in ipairs(train) do ymean = ymean + Y[r] end
    ymean = ymean / #train
    local base_mse = 0
    local ta, tb = {}, {}
    for k, r in ipairs(test) do
        base_mse = base_mse + (Y[r] - ymean) ^ 2
        ta[k], tb[k] = X[r][si], Y[r]
    end
    engine.log(string.format("BASE mean-only mse %.4f; corr(score, y) %.3f", base_mse / #test, correlation(ta, tb, #test)))
    local H = config.hidden or 48
    local rnd = generator(config.seed or 1)
    local epochs = config.epochs or 8
    local decay = config.decay or 0.6
    local order = {}
    for k = 1, #train do order[k] = train[k] end
    -- One model by SGD: hidden = 0 is the linear fit (the second baseline), else the network. Returns the weights
    -- and the last test correlation.
    local function fit(hidden, rate)
        local W1, b1, W2, b2 = {}, {}, {}, ymean
        local scale1 = math.sqrt(2 / n)
        for j = 1, hidden do
            local row = {}
            for f = 1, n do row[f] = (rnd() * 2 - 1) * scale1 end
            W1[j] = row; b1[j] = 0; W2[j] = (rnd() * 2 - 1) * math.sqrt(1 / hidden)
        end
        local linear = {}
        for f = 1, n do linear[f] = 0 end
        local h = {}
        local last = 0
        for epoch = 1, epochs do
            for k = #order, 2, -1 do
                local j = math.floor(rnd() * k) + 1
                order[k], order[j] = order[j], order[k]
            end
            local lr = rate * (decay ^ (epoch - 1))
            local loss = 0
            for _, r in ipairs(order) do
                local x = X[r]
                local out = b2
                if hidden > 0 then
                    for j = 1, hidden do
                        local w = W1[j]
                        local s = b1[j]
                        for f = 1, n do s = s + w[f] * x[f] end
                        if s < 0 then s = 0 end
                        h[j] = s
                        out = out + W2[j] * s
                    end
                else
                    for f = 1, n do out = out + linear[f] * x[f] end
                end
                local err = out - Y[r]
                loss = loss + err * err
                -- (The error clipped as the outcome is: one wild prediction does not throw the weights.)
                if err > 4 then err = 4 elseif err < -4 then err = -4 end
                local g = err * lr
                b2 = b2 - g
                if hidden > 0 then
                    for j = 1, hidden do
                        local hj = h[j]
                        if hj > 0 then
                            local gh = g * W2[j]
                            W2[j] = W2[j] - g * hj
                            b1[j] = b1[j] - gh
                            local w = W1[j]
                            for f = 1, n do w[f] = w[f] - gh * x[f] end
                        end
                    end
                else
                    for f = 1, n do linear[f] = linear[f] - g * x[f] end
                end
            end
            local mse = 0
            for k, r in ipairs(test) do
                local x = X[r]
                local out = b2
                if hidden > 0 then
                    for j = 1, hidden do
                        local w = W1[j]
                        local s = b1[j]
                        for f = 1, n do s = s + w[f] * x[f] end
                        if s > 0 then out = out + W2[j] * s end
                    end
                else
                    for f = 1, n do out = out + linear[f] * x[f] end
                end
                mse = mse + (out - Y[r]) ^ 2
                ta[k] = out
            end
            last = correlation(ta, tb, #test)
            engine.log(string.format("%s epoch %d: train mse %.4f, test mse %.4f, corr %.3f",
                hidden > 0 and ("NET" .. hidden) or "LINEAR", epoch, loss / #order, mse / #test, last))
        end
        return {W1 = W1, b1 = b1, W2 = W2, b2 = b2, linear = linear}, last
    end
    local rate = config.rate or 0.01
    fit(0, rate / 4)
    local net, corr = fit(H, rate)
    engine.log(string.format("NET done: %d records, %d hidden, %d epochs, test corr %.3f", count, H, epochs, corr))
    -- The network, one line each: the text of xoi/brain.txt.
    if config.weights ~= false then
        local function list(values, format)
            local t = {}
            for f = 1, n do t[f] = string.format(format, values[f]) end
            return table.concat(t, " ")
        end
        engine.log(string.format("XOI_BRAIN inputs %d hidden %d", n, H))
        engine.log("XOI_BRAIN mean " .. list(mean, "%.6g"))
        engine.log("XOI_BRAIN sd " .. list(sd, "%.6g"))
        for j = 1, H do
            engine.log(string.format("XOI_BRAIN w1 %d %s b %.5g w2 %.5g", j, list(net.W1[j], "%.5g"), net.b1[j], net.W2[j]))
        end
        engine.log(string.format("XOI_BRAIN b2 %.6g", net.b2))
    end
end
return job
