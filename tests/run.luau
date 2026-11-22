--!strict
-- Copyright (C) 2026 Rocks
-- SPDX-License-Identifier: GPL-3.0-or-later
--[[
	Runs every spec under Tests with Jest. Prints Jest's report and returns the counts of passed
	and failed tests; raises when any test failed or the run itself broke. Load the built test
	model (see docs/testing.md) and call:

		require(StrataTests.Tests.run)()

	Run from a fresh copy of the model each time, since `require` caches modules per session.
]]

local Root = script.Parent.Parent

local Jest = require(Root.DevPackages.Jest)

return function (): (number, number)
	local status, value = Jest.runCLI(Root.Tests, { verbose = true, ci = false }, { Root.Tests }):awaitStatus()

	if status ~= "Resolved" then
		error(`Jest did not finish: {value}`, 0)
	end

	local results = value.results
	local passed, failed = results.numPassedTests, results.numFailedTests

	if failed > 0 or results.numFailedTestSuites > 0 then
		error(`{failed} test(s) failed, {passed} passed`, 0)
	end

	return passed, failed
end
