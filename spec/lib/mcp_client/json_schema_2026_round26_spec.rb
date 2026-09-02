# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-sixth round: the depth bound the
# walk applies counts descents into a child instance value, not every frame of
# the walk. A recursive schema composed through a few `$defs` mixins applies
# several subschemas to each instance level — `$ref` hops, allOf/anyOf/if
# branches — and counting those made the frame count a multiple of the
# instance depth, so JSON that `JSON.parse` accepts (its default max_nesting
# is 100) aborted as "nested too deep". Same-instance recursion stays bounded
# by the `$ref` hop budget and the node-visit cap, as before, and an instance
# that really does nest past the bound still aborts with one validation error
# rather than a SystemStackError.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 26' do
  let(:validator) { MCPClient::SchemaValidator }

  # A recursive schema whose every level is assembled from several `$defs`
  # mixins and composition branches, all applied to the same instance value.
  let(:composed) do
    {
      '$ref' => '#/$defs/node',
      '$defs' => {
        'named' => { 'type' => 'object', 'required' => ['name'] },
        'tagged' => { 'anyOf' => [{ '$ref' => '#/$defs/named' }, { 'type' => 'object' }] },
        # The recursion runs through the mixins, so every instance level is
        # reached through a handful of frames applied to the same value.
        'nested' => { 'properties' => { 'child' => { '$ref' => '#/$defs/node' } } },
        'section' => { 'allOf' => [{ '$ref' => '#/$defs/nested' }] },
        'body' => { 'allOf' => [{ '$ref' => '#/$defs/tagged' }, { '$ref' => '#/$defs/section' }] },
        'node' => {
          'type' => 'object',
          'allOf' => [{ '$ref' => '#/$defs/named' }, { '$ref' => '#/$defs/body' }],
          'anyOf' => [{ '$ref' => '#/$defs/tagged' }],
          'if' => { '$ref' => '#/$defs/named' },
          'then' => { '$ref' => '#/$defs/tagged' }
        }
      }
    }
  end

  # An instance `depth` levels deep, each level a node the schema above
  # describes.
  def chain(depth)
    (1...depth).reduce({ 'name' => 'leaf' }) { |inner, i| { 'name' => "n#{i}", 'child' => inner } }
  end

  describe 'a recursive schema composed through several mixins' do
    it 'accepts an instance as deep as the wire allows' do
      data = chain(99)

      expect(JSON.parse(JSON.generate(data))).to eq(data)
      expect(validator.validate(data, composed)).to be_empty
    end

    it 'still reports a mismatch at that depth rather than aborting' do
      data = chain(99)
      deepest = data
      deepest = deepest['child'] while deepest['child']
      deepest.delete('name')

      errors = validator.validate(data, composed)

      expect(errors).not_to be_empty
      expect(errors).to all(satisfy { |e| !e.include?('validation aborted') })
    end

    it 'accepts an instance at ordinary depths' do
      expect(validator.validate(chain(20), composed)).to be_empty
    end
  end

  describe 'an instance that really does nest past the bound' do
    let(:recursive) { { 'type' => 'array', 'items' => { '$ref' => '#' } } }

    def nest(depth, seed = [])
      (1..depth).reduce(seed) { |nested, _| [nested] }
    end

    it 'aborts on the counted descent, with a single validation error' do
      expect(validator.validate(nest(5000), recursive))
        .to contain_exactly(a_string_matching(/validation aborted: instance nested deeper than 256/))
    end

    it 'aborts the same way on a thread, whose stack is smaller' do
      result = Thread.new { validator.validate(nest(5000), recursive) }.value

      expect(result).to contain_exactly(a_string_matching(/validation aborted: instance nested deeper than 256/))
    end

    # The depth bound counts instance levels, not what one level costs on the
    # stack, and a composed schema spends several frames per level. A stack
    # that runs out before the count does still ends as one validation error.
    it 'aborts on the composed schema on a thread rather than raising SystemStackError' do
      result = Thread.new { validator.validate(chain(5000), composed) }.value

      expect(result).to contain_exactly(a_string_matching(/validation aborted/))
    end
  end

  describe 'a schema that recurses on the same instance value forever' do
    it 'is still stopped by the $ref hop budget' do
      schema = { '$ref' => '#/$defs/a', '$defs' => { 'a' => { 'allOf' => [{ '$ref' => '#/$defs/a' }] } } }

      hops = /validation aborted: \$ref chain exceeds #{validator::MAX_REF_DEPTH} hops/

      expect(validator.validate({ 'x' => 1 }, schema)).to contain_exactly(a_string_matching(hops))
    end
  end
end
