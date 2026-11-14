-- train: a small network over the records of `record` (REC lines), predicting what a move brought (HP dealt minus
-- HP taken over the window, in hundreds) from the situation and the move — the "brain" XOI weighs with its own
-- score (scripts/base/game/smart_ai.lua, brain_kit). Inputs 58 -> hidden H (ReLU) -> 1, plain SGD; LuaJIT does
-- about 150,000 samples a second for H = 48, so a few million records train in minutes an epoch.
--   The records: files xoi/data_1.txt, xoi/data_2.txt, ... in the pack (hoc-sau.bat packs the gathered REC lines so,
--   each file under 4 MB — a script reads a resource up to 4 MiB), or bench modules <data>_1, <data>_2, ... /
--   <data> returning {text = "..."} (data = "rec_data").
--   hidden (48), epochs (8), rate (0.01, times `decay` (0.6) each epoch), holdout (every n-th record kept for the
--   test: 5), stride (1: every record; k keeps every k-th, for a quicker look at a big set), seed, weights (false:
--   no XOI_BRAIN lines, the figures only). A record takes about 500 bytes of memory: six million, 3 GB — so with
--   `records` (how many the files hold, which hoc-sau.bat counts as it packs them) more than `max_records`
--   (6,000,000) are thinned to every k-th record, the rounds all still represented (`stride` given wins).
--   target (1): which outcome to learn when the records carry several windows (record.lua's windows: the REC
--   line holds the first, an RW line after it the others) — 1 the REC line's, k the (k-1)-th pair of the RW line;
--   a record with no RW line after it is left out for k > 1.
--   Records of 88 numbers (record.lua from package 82: the 58, then smart_ai.lua's brain_kit.extra_names) make a
--   brain of the second kind: the 86 plain numbers standardized as the 58 are, and the two fighters' ids given as
--   one input per fighter seen in the records (for the fighter, and again for the target: 0 but for the one it is —
--   two weights a hidden unit to add, not a hundred to multiply). The one that is counts as much as standardizing
--   it would make it, 1 over the spread of its 0s and 1s (a fighter in one record of twenty: 4.4; at most 20): the
--   brain's file gives such an input mean 0 and that spread. The file says it is of the second kind ("XOI_BRAIN
--   inputs N hidden H extra 28", "XOI_BRAIN ids ..."). Such a record takes about 750 bytes: max_records is 4,000,000
--   for them (3 GB). Records of 58 numbers make a brain of the first kind, as before.
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
    -- (The kind of the records, at the first one: 88 numbers, the second; how many fit decides the stride.)
    local second = false
    local plain = nil
    local function first_record(m)
        n = m
        second = m == 88
        plain = second and 86 or m
        local max_records = config.max_records or (second and 4000000 or 6000000)
        if not config.stride and config.records and config.records > max_records then
            stride = math.ceil(config.records / max_records)
            engine.log(string.format("records: %d in the files, every %dth kept (memory: about %d bytes a record)",
                config.records, stride, second and 750 or 500))
        end
    end
    local tokens = {}
    -- (target > 1: a REC line's row waits for the RW line after it — kept across files —, whose pair it then takes.)
    local target = config.target or 1
    local waiting = nil
    local no_rw = 0
    local function commit(row, dealt, taken)
        count = count + 1
        X[count] = row
        local y = (dealt - taken) / 100
        if y > 2 then y = 2 elseif y < -2 then y = -2 end
        Y[count] = y
    end
    local function take(text)
        files, bytes = files + 1, bytes + #text
        for line in text:gmatch("[^\r\n]+") do
            if target > 1 and line:sub(1, 3) == "RW " then
                if waiting then
                    local pairs_of, k = {}, 0
                    for token in line:gmatch("%S+") do
                        k = k + 1
                        if k > 1 then pairs_of[#pairs_of + 1] = tonumber(token) end
                    end
                    local dealt, taken = pairs_of[2 * (target - 1) - 1], pairs_of[2 * (target - 1)]
                    if dealt and taken then commit(waiting, dealt, taken) else dropped = dropped + 1 end
                    waiting = nil
                end
            elseif line:sub(1, 4) == "REC " then
                if waiting then no_rw = no_rw + 1; waiting = nil end
                seen = seen + 1
                if n == nil or seen % stride == 0 then
                    local k = 0
                    for token in line:gmatch("%S+") do
                        k = k + 1
                        tokens[k] = token
                    end
                    -- tokens[1] = "REC", [2] slot, [3] dealt, [4] taken, [5..] features
                    local dealt, taken = tonumber(tokens[3]), tonumber(tokens[4])
                    local m = k - 4
                    if n == nil and m > 0 then
                        first_record(m)
                        if seen % stride ~= 0 then goto next_line end
                    end
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
                        if target > 1 then waiting = row else commit(row, dealt, taken) end
                    else
                        dropped = dropped + 1
                    end
                end
            end
            ::next_line::
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
    if waiting then no_rw = no_rw + 1 end
    if target > 1 then
        engine.log(string.format("target %d: the outcome of the RW line's pair %d%s", target, target - 1,
            no_rw > 0 and string.format(" (%d records without an RW line left out)", no_rw) or ""))
    end
    engine.log(string.format("records read from %d file(s), %.1f MB: %d records%s%s", files, bytes / 1048576, count,
        stride > 1 and string.format(" (every %dth of %d)", stride, seen) or "",
        dropped > 0 and string.format(" (%d lines dropped: not a whole record)", dropped) or ""))
    assert(n and count > 100, "too few records")
    -- The second kind: the ids seen (one list for the fighter and the target), each record's two ids turned into
    -- the positions of their inputs (after the plain numbers: the fighter's, then the target's), n the inputs.
    local ids, K = {}, 0
    if second then
        local found = {}
        for r = 1, count do
            local x = X[r]
            found[x[plain + 1]] = true
            found[x[plain + 2]] = true
        end
        for id in pairs(found) do ids[#ids + 1] = id end
        table.sort(ids)
        K = #ids
        local index = {}
        for k, id in ipairs(ids) do index[id] = k end
        for r = 1, count do
            local x = X[r]
            x[plain + 1], x[plain + 2] = plain + index[x[plain + 1]], plain + K + index[x[plain + 2]]
        end
        n = plain + 2 * K
    end
    -- Every holdout-th record is the test's; the rest train.
    local holdout = config.holdout or 5
    local train, test = {}, {}
    for r = 1, count do
        if r % holdout == 0 then test[#test + 1] = r else train[#train + 1] = r end
    end
    -- Standardized in place over the training records' mean and spread, clipped.
    -- (The one-hot inputs: mean 0, and the spread of their 0s and 1s over the training records — the one that is
    -- counts 1 / spread, onehot[position].)
    local onehot = {}
    if second then
        local seen_at = {}
        for f = plain + 1, n do seen_at[f] = 0 end
        for _, r in ipairs(train) do
            local x = X[r]
            seen_at[x[plain + 1]] = seen_at[x[plain + 1]] + 1
            seen_at[x[plain + 2]] = seen_at[x[plain + 2]] + 1
        end
        -- (An id no training record has — only test ones — counts nothing: its weights are written as 0.)
        for f = plain + 1, n do
            local share = seen_at[f] / #train
            local spread = math.sqrt(share * (1 - share))
            if seen_at[f] == 0 then onehot[f] = 0 else onehot[f] = spread > 0.05 and 1 / spread or 20 end
        end
    end
    local mean, sd = {}, {}
    for f = 1, n do mean[f] = 0; sd[f] = 0 end
    for _, r in ipairs(train) do
        local x = X[r]
        for f = 1, plain do mean[f] = mean[f] + x[f] end
    end
    for f = 1, plain do mean[f] = mean[f] / #train end
    for _, r in ipairs(train) do
        local x = X[r]
        for f = 1, plain do local d = x[f] - mean[f]; sd[f] = sd[f] + d * d end
    end
    for f = 1, plain do sd[f] = math.sqrt(sd[f] / #train); if sd[f] < 1e-6 then sd[f] = 1 end end
    for f = plain + 1, n do mean[f], sd[f] = 0, onehot[f] > 0 and 1 / onehot[f] or 1 end
    for r = 1, count do
        local x = X[r]
        for f = 1, plain do
            local v = (x[f] - mean[f]) / sd[f]
            if v > CLIP then v = CLIP elseif v < -CLIP then v = -CLIP end
            x[f] = v
        end
    end
    if second then
        engine.log(string.format("TRAIN %d records (%d train, %d test), %d inputs (%d plain, 2 x %d fighters)", count, #train, #test, n, plain, K))
    else
        engine.log(string.format("TRAIN %d records (%d train, %d test), %d features", count, #train, #test, n))
    end
    -- Baselines: the mean alone, and the player's own score ('score' is the 43rd number).
    local si = config.score_index or 43
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
                -- (The second kind: a and b, the positions of the two one-hot inputs that are 1.)
                local a, b, va, vb = nil, nil, 0, 0
                if second then a, b = x[plain + 1], x[plain + 2]; va, vb = onehot[a], onehot[b] end
                if hidden > 0 then
                    for j = 1, hidden do
                        local w = W1[j]
                        local s = b1[j]
                        for f = 1, plain do s = s + w[f] * x[f] end
                        if a then s = s + w[a] * va + w[b] * vb end
                        if s < 0 then s = 0 end
                        h[j] = s
                        out = out + W2[j] * s
                    end
                else
                    for f = 1, plain do out = out + linear[f] * x[f] end
                    if a then out = out + linear[a] * va + linear[b] * vb end
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
                            for f = 1, plain do w[f] = w[f] - gh * x[f] end
                            if a then w[a] = w[a] - gh * va; w[b] = w[b] - gh * vb end
                        end
                    end
                else
                    for f = 1, plain do linear[f] = linear[f] - g * x[f] end
                    if a then linear[a] = linear[a] - g * va; linear[b] = linear[b] - g * vb end
                end
            end
            local mse = 0
            for k, r in ipairs(test) do
                local x = X[r]
                local out = b2
                local a, b, va, vb = nil, nil, 0, 0
                if second then a, b = x[plain + 1], x[plain + 2]; va, vb = onehot[a], onehot[b] end
                if hidden > 0 then
                    for j = 1, hidden do
                        local w = W1[j]
                        local s = b1[j]
                        for f = 1, plain do s = s + w[f] * x[f] end
                        if a then s = s + w[a] * va + w[b] * vb end
                        if s > 0 then out = out + W2[j] * s end
                    end
                else
                    for f = 1, plain do out = out + linear[f] * x[f] end
                    if a then out = out + linear[a] * va + linear[b] * vb end
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
    if second then
        for f = plain + 1, n do
            if onehot[f] == 0 then for j = 1, H do net.W1[j][f] = 0 end end
        end
    end
    engine.log(string.format("NET done: %d records, %d hidden, %d epochs, test corr %.3f", count, H, epochs, corr))
    -- The network, one line each: the text of xoi/brain.txt.
    if config.weights ~= false then
        local function list(values, format)
            local t = {}
            for f = 1, n do t[f] = string.format(format, values[f]) end
            return table.concat(t, " ")
        end
        if second then
            engine.log(string.format("XOI_BRAIN inputs %d hidden %d extra %d", n, H, plain - 58))
            local names = {}
            for k, id in ipairs(ids) do names[k] = string.format("%d", id) end
            engine.log("XOI_BRAIN ids " .. table.concat(names, " "))
        else
            engine.log(string.format("XOI_BRAIN inputs %d hidden %d", n, H))
        end
        engine.log("XOI_BRAIN mean " .. list(mean, "%.6g"))
        engine.log("XOI_BRAIN sd " .. list(sd, "%.6g"))
        for j = 1, H do
            engine.log(string.format("XOI_BRAIN w1 %d %s b %.5g w2 %.5g", j, list(net.W1[j], "%.5g"), net.b1[j], net.W2[j]))
        end
        engine.log(string.format("XOI_BRAIN b2 %.6g", net.b2))
    end
end
return job
