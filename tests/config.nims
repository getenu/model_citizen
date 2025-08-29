--mm:
  orc
--threads:
  on
--define:
  nim_preview_hash_ref
--define:
  nim_type_names
--define:
  "chronicles_enabled=on"
--define:
  "chronicles_sinks=textlines[stdout]"
--define:
  "chronicles_log_level=INFO"
--define:
  "zen_trace"
--define:
  "metrics"
# --define:"dump_zen_objects"

--experimental:
  "overloadable_enums"

switch("path", "$projectDir/../src")
