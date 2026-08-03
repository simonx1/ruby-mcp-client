# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# Shared safety helpers for the runnable examples.
#
# The LLM examples hand a model a set of MCP tools and execute whatever the
# model picks, with no human in the loop. That is fine for a demo, but only if
# the blast radius is a throwaway directory rather than the checkout — which
# holds the git history, and (when the runner is configured)
# examples/secrets.env with live API tokens.
module ExampleSandbox
  # npm packages the examples launch are pinned rather than floating on
  # @latest, so a compromised or simply changed release cannot silently gain
  # code execution in a process that holds live API credentials. Override to
  # try a newer release, e.g.:
  #   MCP_FS_SERVER_VERSION=2026.8.1 ruby examples/openai_ruby_mcp.rb
  FILESYSTEM_SERVER_VERSION = ENV.fetch('MCP_FS_SERVER_VERSION', '2026.7.10')
  PLAYWRIGHT_MCP_VERSION = ENV.fetch('PLAYWRIGHT_MCP_VERSION', '0.0.78')

  module_function

  # A disposable directory with a few sample files, used as the filesystem
  # server's only root. Deleted when the example exits.
  # @return [String] absolute path to the sandbox root
  def filesystem_root
    @filesystem_root ||= begin
      root = Dir.mktmpdir('mcp-example-sandbox-')
      File.write(File.join(root, 'README.txt'), "Sample file for the MCP filesystem demo.\n")
      File.write(File.join(root, 'notes.md'), "# Notes\n\nAnother sample file.\n")
      FileUtils.mkdir_p(File.join(root, 'subdir'))
      File.write(File.join(root, 'subdir', 'nested.txt'), "A nested sample file.\n")
      at_exit { FileUtils.remove_entry(root) if File.directory?(root) }
      root
    end
  end

  # Command that launches the pinned filesystem MCP server scoped to the
  # sandbox, suitable for MCPClient.connect.
  # @return [Array<String>]
  def filesystem_server_command
    %W[npx -y @modelcontextprotocol/server-filesystem@#{FILESYSTEM_SERVER_VERSION} #{filesystem_root}]
  end

  # Environment overrides that strip credentials from a child process.
  #
  # Pinning the top-level npm package still leaves its transitive dependencies
  # on version ranges, so `npx` can execute code this repo never pinned. The
  # child also inherits the parent environment by default — which for these
  # examples holds live API keys, and under examples/run_all_examples.sh the
  # whole of secrets.env. Passing a key with a nil value makes Open3 unset it
  # in the child, so a compromised package has nothing to exfiltrate.
  #
  # @param extra [Hash] additional variables the child does need
  # @return [Hash] env hash for MCPClient.connect(env:)
  def secret_free_env(extra = {})
    stripped = ENV.keys.grep(/(_KEY|_TOKEN|_SECRET|CREDENTIAL|PASSWORD|AUTH)/i)
                  .to_h { |key| [key, nil] }
    stripped.merge(extra)
  end

  # Print the standing caveat for examples that execute model-selected tools.
  # @param scope [String] what the model can reach in this example
  # @return [void]
  def announce_auto_execution(scope)
    warn <<~WARNING
      NOTE: this example executes whatever tool the model selects, without asking.
      Reachable in this run: #{scope}
      Production hosts should gate side-effecting tools behind user approval and
      an explicit allowlist.
    WARNING
  end
end
