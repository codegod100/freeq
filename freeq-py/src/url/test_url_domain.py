# 🔴 RED: Tests designed to FAIL — fix implementation to pass
# URL Domain (IU-47ca9242)
# Risk Tier: HIGH

# TDD CYCLE:
# 1. pytest test_url_domain.py -v
# 2. 🔴 See RED (tests fail)
# 3. Fix url_domain.py implementations
# 4. 🟢 See GREEN (tests pass)

import pytest
from url_domain import _phoenix, Url, process

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "47ca92422eff65e3ccd5a88ae4761d2e1e9349187027c71357b1a8381a512a65"

# 🔴 RED: This test will FAIL until you fix process()
def test_process_transforms_input():
    input_item = Url(id="123", name="In")
    result = process(input_item)
    # 🔴 This FAILS because process returns input unchanged
    assert result is not input_item  # Should be new object
    # FIX: Actually transform/process the input
    # Then add: assert result.name == "Expected Output"
