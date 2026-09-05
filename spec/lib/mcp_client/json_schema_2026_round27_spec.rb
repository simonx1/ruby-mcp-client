# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-seventh round.
#
# Round 26 stopped counting the frames a schema spends on one instance value
# against the depth bound, but those frames still sat on the Ruby call stack:
# a recursive schema composed through N `$defs` mixins spent N of them per
# instance level, so the stack grew with the product of instance depth and
# mixin count and a conforming `structuredContent` aborted with
# "schema too deeply recursive for this stack". The same-instance
# applications — a `$ref` hop, an allOf/anyOf/oneOf/not/if branch, a
# then/else — are now applied iteratively, so a frame is spent only on a step
# into a child value and MAX_NODE_DEPTH genuinely bounds the stack.
#
# Also: a draft-07 `$id` is a URI reference, so its fragment is
# percent-decoded when the plain name it declares is read, exactly as a
# `$ref`'s fragment is.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 27' do
  let(:validator) { MCPClient::SchemaValidator }

  # A recursive schema whose every instance level is reached through `count`
  # mixins applied to the same value: the innermost one carries the descent
  # into the array's items, the rest only wrap it in one more same-instance
  # application. The mixin count is the dimension round 26's spec never
  # varied — it is what multiplies the frames one instance level costs.
  def mixin_schema(count, keyword)
    defs = { 'leaf' => { 'type' => 'array', 'items' => { '$ref' => '#' } } }
    (0...count).each do |i|
      inner = { '$ref' => i + 1 < count ? "#/$defs/n#{i + 1}" : '#/$defs/leaf' }
      defs["n#{i}"] = case keyword
                      when 'if' then { 'if' => { 'type' => 'array' }, 'then' => inner }
                      when '$ref' then inner
                      else { keyword => [inner] }
                      end
    end
    { '$ref' => '#/$defs/n0', '$defs' => defs }
  end

  # An array nested `depth` levels deep — data every JSON parser accepts
  # (`JSON.parse`'s default max_nesting is 100).
  def nest(depth)
    (1..depth).reduce([]) { |nested, _| [nested] }
  end

  # The deepest instance the schema validates without an abort, searched
  # between 1 and MAX_NODE_DEPTH.
  def deepest_accepted(schema, on_thread: false)
    low = 0
    high = validator::MAX_NODE_DEPTH
    while low < high
      mid = ((low + high) / 2) + 1
      run = -> { validator.validate(nest(mid), schema) }
      if (on_thread ? Thread.new(&run).value : run.call).empty?
        low = mid
      else
        high = mid - 1
      end
    end
    low
  end

  describe 'a recursive schema composed through a varying number of mixins' do
    # 16 mixins keep the per-level `$ref` chain inside MAX_REF_DEPTH, which
    # is the budget that is meant to bound same-instance recursion.
    mixin_counts = [1, 2, 4, 8, 16]

    %w[allOf anyOf oneOf if $ref].each do |keyword|
      mixin_counts.each do |count|
        context "with #{count} #{keyword} mixins" do
          let(:schema) { mixin_schema(count, keyword) }

          it 'is a usable schema' do
            expect(validator.check_schema(schema)).to be_empty
          end

          it 'validates an instance as deep as the wire allows' do
            data = nest(99)

            expect(JSON.parse(JSON.generate(data))).to eq(data)
            expect(validator.validate(data, schema)).to be_empty
          end

          # A transport's reader thread has a smaller stack than the main
          # one, and that is where a tool result is actually validated.
          it 'validates that instance on a thread too' do
            expect(Thread.new { validator.validate(nest(99), schema) }.value).to be_empty
          end

          # The bound the validator names is the bound it applies: the mixin
          # count no longer eats into it.
          it 'accepts the instance depth its bound promises, on either stack' do
            expect(deepest_accepted(schema)).to eq(validator::MAX_NODE_DEPTH)
            expect(deepest_accepted(schema, on_thread: true)).to eq(validator::MAX_NODE_DEPTH)
          end
        end
      end
    end
  end

  describe 'an instance nested past the bound, under a composed schema' do
    let(:schema) { mixin_schema(8, 'allOf') }

    it 'aborts on the counted descent rather than on the stack' do
      expect(validator.validate(nest(validator::MAX_NODE_DEPTH + 1), schema))
        .to contain_exactly(a_string_matching(/aborted: instance nested deeper than #{validator::MAX_NODE_DEPTH}/))
    end

    it 'aborts the same way on a thread' do
      result = Thread.new { validator.validate(nest(validator::MAX_NODE_DEPTH + 1), schema) }.value

      expect(result)
        .to contain_exactly(a_string_matching(/aborted: instance nested deeper than #{validator::MAX_NODE_DEPTH}/))
    end
  end

  describe 'a schema that recurses on the same instance value forever' do
    it 'is still stopped by the $ref hop budget, not by the stack' do
      schema = { '$ref' => '#/$defs/a', '$defs' => { 'a' => { 'allOf' => [{ '$ref' => '#/$defs/a' }] } } }
      hops = /validation aborted: \$ref chain exceeds #{validator::MAX_REF_DEPTH} hops/

      expect(validator.validate({ 'x' => 1 }, schema)).to contain_exactly(a_string_matching(hops))
    end

    it 'is stopped the same way on a thread' do
      schema = { '$ref' => '#/$defs/a', '$defs' => { 'a' => { 'anyOf' => [{ '$ref' => '#/$defs/a' }] } } }
      result = Thread.new { validator.validate({ 'x' => 1 }, schema) }.value

      expect(result).to contain_exactly(a_string_matching(/validation aborted: \$ref chain exceeds/))
    end
  end

  describe 'a draft-07 $id whose fragment is percent-encoded' do
    let(:schema) do
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        '$ref' => '#foo%2Dbar',
        'definitions' => { 'target' => { '$id' => '#foo%2Dbar', 'type' => 'integer' } }
      }
    end

    it 'declares the decoded plain name, so the matching $ref resolves' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(7, schema)).to be_empty
    end

    it 'still applies the target it names' do
      expect(validator.validate('seven', schema))
        .to contain_exactly(a_string_matching(/expected type integer, got string/))
    end

    it 'resolves an undecoded $ref against the decoded name it declares' do
      undecoded = {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        '$ref' => '#foo-bar',
        'definitions' => { 'target' => { '$id' => '#foo%2Dbar', 'type' => 'integer' } }
      }

      expect(validator.check_schema(undecoded)).to be_empty
      expect(validator.validate('seven', undecoded))
        .to contain_exactly(a_string_matching(/expected type integer, got string/))
    end

    it 'names nothing when the escape is malformed' do
      malformed = {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        '$ref' => '#a%ZZ',
        'definitions' => { 'target' => { '$id' => '#a%ZZ', 'type' => 'integer' } }
      }

      expect(validator.check_schema(malformed))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end
end
