## Summary

<!-- What does this change and why? Link any related issue. -->

## Test plan

<!-- How was this verified? -->

- [ ] `panel.lua` / `init.lua` parse clean
      (`nvim --headless -c "lua loadfile('lua/dimfort/panel.lua')" -c qa`)
- [ ] Manual smoke test against a local DimFort server
- [ ] `MANUAL_QA.md` items covering the change pass
- [ ] Docs updated if behaviour changed (README / CHANGELOG / MANUAL_QA)
