# frozen_string_literal: true

require 'weibo_import/cli'
require 'weibo_import/importer'
require 'weibo_import/verify'
require 'weibo_import/rollback'
require 'weibo_import/silence'
require 'weibo_import/ledger'

class CliTest < Minitest::Test
  def parse(args)
    WeiboImport::CLI.new.parse(args)
  end

  def test_valid_plan_invocation
    cli = parse(['plan', '--account', 'me', '--input', 'normalized.jsonl', '--limit', '20', '--visibility', 'private'])
    assert_equal 'plan', cli.subcommand
    assert_equal 'me', cli.options[:account]
    assert_equal 20, cli.options[:limit]
    assert_equal 'private', cli.options[:visibility]
    refute cli.placeholder?
  end

  def test_defaults
    cli = parse(['plan', '--account', 'me', '--input', 'x.jsonl'])
    assert_equal 'unlisted', cli.options[:visibility] # 默认 unlisted（收紧侧）
    assert_nil cli.options[:limit]
    assert cli.options[:dry_run]
    refute cli.options[:execute]
  end

  def test_plan_requires_account_and_input
    e = assert_raises(WeiboImport::CLI::ParseFailure) { parse(['plan', '--input', 'x.jsonl']) }
    assert_includes e.message, '--account'
    e2 = assert_raises(WeiboImport::CLI::ParseFailure) { parse(['plan', '--account', 'me']) }
    assert_includes e2.message, '--input'
  end

  def test_unknown_or_missing_subcommand
    assert_raises(WeiboImport::CLI::ParseFailure) { parse(['bogus']) }
    assert_raises(WeiboImport::CLI::ParseFailure) { parse([]) }
    assert_raises(WeiboImport::CLI::ParseFailure) { parse(['plan', '--account', 'me', '--input', 'x', 'extra']) }
  end

  def test_invalid_visibility_rejected
    assert_raises(WeiboImport::CLI::ParseFailure) { parse(['plan', '--account', 'me', '--input', 'x', '--visibility', 'followers']) }
  end

  def test_placeholder_subcommands_flagged
    %w[import verify rollback].each do |sub|
      cli = parse([sub])
      assert_equal sub, cli.subcommand
      assert cli.placeholder?
    end
    assert_equal 2, WeiboImport::CLI::PLACEHOLDER_EXIT_CODE
    # setup-ledger 已实装，不再是占位
    refute parse(['setup-ledger']).placeholder?
  end

  def test_placeholder_modules_refuse_to_run
    assert_equal 2, WeiboImport::Importer.run(parse(['import']))
    assert_equal 2, WeiboImport::Verify.run(parse(['verify']))
    assert_equal 2, WeiboImport::Rollback.run(parse(['rollback']))
  end
end
