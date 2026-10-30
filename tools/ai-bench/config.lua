-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- The job this bench runs (see README.md). INSANE! ("smart") against the original computer player ("classic"),
-- four games per pair of fighter ids, the first fighter of a pair played by the first brain.
return {command = "duel", brains = {"smart", "classic"}, games = 4, difficulty = -1, limit = 9000, verbose = true, usage = true,
    pairs = {{1, 2}, {2, 1}}}
