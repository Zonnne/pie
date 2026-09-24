tmp = Path.join(System.tmp_dir!(), "pie-test-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)
System.put_env("PIE_HOME", tmp)
System.delete_env("ANTHROPIC_BASE_URL")

# Generous receive timeout: several tests wait on real processes and ports.
ExUnit.start(assert_receive_timeout: 1_000)
