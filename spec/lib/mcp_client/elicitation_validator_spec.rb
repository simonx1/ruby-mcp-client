# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ElicitationValidator do
  describe '.validate_schema' do
    context 'with valid schemas' do
      it 'accepts a simple string property' do
        schema = {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string' }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts string with all optional attributes' do
        schema = {
          'type' => 'object',
          'properties' => {
            'email' => {
              'type' => 'string',
              'title' => 'Email',
              'description' => 'Your email',
              'minLength' => 3,
              'maxLength' => 50,
              'pattern' => '^[A-Za-z]+$',
              'format' => 'email',
              'default' => 'user@example.com'
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts number property with bounds' do
        schema = {
          'type' => 'object',
          'properties' => {
            'age' => {
              'type' => 'number',
              'minimum' => 0,
              'maximum' => 150,
              'default' => 25
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts integer property' do
        schema = {
          'type' => 'object',
          'properties' => {
            'count' => {
              'type' => 'integer',
              'minimum' => 1,
              'maximum' => 100
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts boolean property' do
        schema = {
          'type' => 'object',
          'properties' => {
            'confirmed' => {
              'type' => 'boolean',
              'default' => false
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts string enum property' do
        schema = {
          'type' => 'object',
          'properties' => {
            'color' => {
              'type' => 'string',
              'enum' => %w[Red Green Blue]
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts string enum with oneOf (titled values)' do
        schema = {
          'type' => 'object',
          'properties' => {
            'color' => {
              'type' => 'string',
              'oneOf' => [
                { 'const' => '#FF0000', 'title' => 'Red' },
                { 'const' => '#00FF00', 'title' => 'Green' }
              ]
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts array multi-select enum with items.enum' do
        schema = {
          'type' => 'object',
          'properties' => {
            'colors' => {
              'type' => 'array',
              'items' => {
                'type' => 'string',
                'enum' => %w[Red Green Blue]
              },
              'minItems' => 1,
              'maxItems' => 2
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts array multi-select enum with items.anyOf (titled)' do
        schema = {
          'type' => 'object',
          'properties' => {
            'colors' => {
              'type' => 'array',
              'items' => {
                'anyOf' => [
                  { 'const' => '#FF0000', 'title' => 'Red' },
                  { 'const' => '#00FF00', 'title' => 'Green' }
                ]
              }
            }
          }
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts mixed property types' do
        schema = {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string' },
            'age' => { 'type' => 'number', 'minimum' => 18 },
            'confirmed' => { 'type' => 'boolean' },
            'env' => { 'type' => 'string', 'enum' => %w[dev staging prod] }
          },
          'required' => %w[name age]
        }
        expect(described_class.validate_schema(schema)).to be_empty
      end

      it 'accepts all valid string formats' do
        %w[email uri date date-time].each do |fmt|
          schema = {
            'type' => 'object',
            'properties' => {
              'field' => { 'type' => 'string', 'format' => fmt }
            }
          }
          expect(described_class.validate_schema(schema)).to be_empty, "Expected format '#{fmt}' to be valid"
        end
      end
    end

    context 'with invalid schemas' do
      it 'rejects non-object root type' do
        schema = { 'type' => 'string' }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/type must be 'object'/))
      end

      it 'rejects unsupported property type' do
        schema = {
          'type' => 'object',
          'properties' => {
            'data' => { 'type' => 'object' }
          }
        }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/unsupported type 'object'/))
      end

      it 'rejects unsupported string format' do
        schema = {
          'type' => 'object',
          'properties' => {
            'field' => { 'type' => 'string', 'format' => 'uuid' }
          }
        }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/unsupported format 'uuid'/))
      end

      it 'rejects non-array enum' do
        schema = {
          'type' => 'object',
          'properties' => {
            'field' => { 'type' => 'string', 'enum' => 'not_array' }
          }
        }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/enum must be an array/))
      end

      it 'rejects non-numeric minimum' do
        schema = {
          'type' => 'object',
          'properties' => {
            'field' => { 'type' => 'number', 'minimum' => 'five' }
          }
        }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/minimum must be numeric/))
      end

      it 'rejects array without items' do
        schema = {
          'type' => 'object',
          'properties' => {
            'field' => { 'type' => 'array' }
          }
        }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/requires 'items' definition/))
      end

      it 'rejects array items without enum or anyOf' do
        schema = {
          'type' => 'object',
          'properties' => {
            'field' => {
              'type' => 'array',
              'items' => { 'type' => 'string' }
            }
          }
        }
        errors = described_class.validate_schema(schema)
        expect(errors).to include(match(/must have 'enum' or 'anyOf'/))
      end
    end

    context 'with nil or non-hash input' do
      it 'returns empty for nil' do
        expect(described_class.validate_schema(nil)).to be_empty
      end

      it 'returns empty for non-hash' do
        expect(described_class.validate_schema('string')).to be_empty
      end
    end
  end

  describe '.validate_content' do
    context 'string validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string', 'minLength' => 2, 'maxLength' => 10 }
          },
          'required' => ['name']
        }
      end

      it 'accepts valid string' do
        errors = described_class.validate_content({ 'name' => 'Alice' }, schema)
        expect(errors).to be_empty
      end

      it 'rejects missing required field' do
        errors = described_class.validate_content({}, schema)
        expect(errors).to include(match(/Missing required field 'name'/))
      end

      it 'rejects non-string value' do
        errors = described_class.validate_content({ 'name' => 123 }, schema)
        expect(errors).to include(match(/must be a string/))
      end

      it 'rejects string shorter than minLength' do
        errors = described_class.validate_content({ 'name' => 'A' }, schema)
        expect(errors).to include(match(/at least 2 characters/))
      end

      it 'rejects string longer than maxLength' do
        errors = described_class.validate_content({ 'name' => 'A' * 11 }, schema)
        expect(errors).to include(match(/at most 10 characters/))
      end
    end

    context 'string enum validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'color' => {
              'type' => 'string',
              'enum' => %w[Red Green Blue]
            }
          }
        }
      end

      it 'accepts valid enum value' do
        errors = described_class.validate_content({ 'color' => 'Red' }, schema)
        expect(errors).to be_empty
      end

      it 'rejects invalid enum value' do
        errors = described_class.validate_content({ 'color' => 'Yellow' }, schema)
        expect(errors).to include(match(/must be one of: Red, Green, Blue/))
      end
    end

    context 'string with oneOf (titled enum) validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'color' => {
              'type' => 'string',
              'oneOf' => [
                { 'const' => '#FF0000', 'title' => 'Red' },
                { 'const' => '#00FF00', 'title' => 'Green' }
              ]
            }
          }
        }
      end

      it 'accepts valid const value' do
        errors = described_class.validate_content({ 'color' => '#FF0000' }, schema)
        expect(errors).to be_empty
      end

      it 'rejects invalid const value' do
        errors = described_class.validate_content({ 'color' => '#0000FF' }, schema)
        expect(errors).to include(match(/must be one of/))
      end
    end

    context 'string pattern validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'version' => {
              'type' => 'string',
              'pattern' => '^v\\d+\\.\\d+\\.\\d+$'
            }
          }
        }
      end

      it 'accepts matching pattern' do
        errors = described_class.validate_content({ 'version' => 'v1.2.3' }, schema)
        expect(errors).to be_empty
      end

      it 'rejects non-matching pattern' do
        errors = described_class.validate_content({ 'version' => 'invalid' }, schema)
        expect(errors).to include(match(/must match pattern/))
      end
    end

    context 'number validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'age' => { 'type' => 'number', 'minimum' => 0, 'maximum' => 150 }
          },
          'required' => ['age']
        }
      end

      it 'accepts valid number' do
        errors = described_class.validate_content({ 'age' => 25 }, schema)
        expect(errors).to be_empty
      end

      it 'accepts float number' do
        errors = described_class.validate_content({ 'age' => 25.5 }, schema)
        expect(errors).to be_empty
      end

      it 'rejects non-numeric value' do
        errors = described_class.validate_content({ 'age' => 'twenty' }, schema)
        expect(errors).to include(match(/must be a number/))
      end

      it 'rejects value below minimum' do
        errors = described_class.validate_content({ 'age' => -1 }, schema)
        expect(errors).to include(match(/must be >= 0/))
      end

      it 'rejects value above maximum' do
        errors = described_class.validate_content({ 'age' => 200 }, schema)
        expect(errors).to include(match(/must be <= 150/))
      end
    end

    context 'integer validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'count' => { 'type' => 'integer', 'minimum' => 1 }
          }
        }
      end

      it 'accepts valid integer' do
        errors = described_class.validate_content({ 'count' => 5 }, schema)
        expect(errors).to be_empty
      end

      it 'rejects float for integer type' do
        errors = described_class.validate_content({ 'count' => 5.5 }, schema)
        expect(errors).to include(match(/must be an integer/))
      end
    end

    context 'boolean validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'confirmed' => { 'type' => 'boolean' }
          }
        }
      end

      it 'accepts true' do
        errors = described_class.validate_content({ 'confirmed' => true }, schema)
        expect(errors).to be_empty
      end

      it 'accepts false' do
        errors = described_class.validate_content({ 'confirmed' => false }, schema)
        expect(errors).to be_empty
      end

      it 'rejects non-boolean' do
        errors = described_class.validate_content({ 'confirmed' => 'yes' }, schema)
        expect(errors).to include(match(/must be a boolean/))
      end
    end

    context 'array (multi-select enum) validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'colors' => {
              'type' => 'array',
              'items' => { 'type' => 'string', 'enum' => %w[Red Green Blue] },
              'minItems' => 1,
              'maxItems' => 2
            }
          }
        }
      end

      it 'accepts valid array selection' do
        errors = described_class.validate_content({ 'colors' => ['Red'] }, schema)
        expect(errors).to be_empty
      end

      it 'accepts multiple valid selections' do
        errors = described_class.validate_content({ 'colors' => %w[Red Green] }, schema)
        expect(errors).to be_empty
      end

      it 'rejects non-array value' do
        errors = described_class.validate_content({ 'colors' => 'Red' }, schema)
        expect(errors).to include(match(/must be an array/))
      end

      it 'rejects invalid array element' do
        errors = described_class.validate_content({ 'colors' => ['Yellow'] }, schema)
        expect(errors).to include(match(/contains invalid value 'Yellow'/))
      end

      it 'rejects too few items' do
        errors = described_class.validate_content({ 'colors' => [] }, schema)
        expect(errors).to include(match(/at least 1 items/))
      end

      it 'rejects too many items' do
        errors = described_class.validate_content({ 'colors' => %w[Red Green Blue] }, schema)
        expect(errors).to include(match(/at most 2 items/))
      end
    end

    context 'array with anyOf (titled multi-select) validation' do
      let(:schema) do
        {
          'type' => 'object',
          'properties' => {
            'colors' => {
              'type' => 'array',
              'items' => {
                'anyOf' => [
                  { 'const' => '#FF0000', 'title' => 'Red' },
                  { 'const' => '#00FF00', 'title' => 'Green' }
                ]
              }
            }
          }
        }
      end

      it 'accepts valid const values' do
        errors = described_class.validate_content({ 'colors' => ['#FF0000'] }, schema)
        expect(errors).to be_empty
      end

      it 'rejects invalid const values' do
        errors = described_class.validate_content({ 'colors' => ['#0000FF'] }, schema)
        expect(errors).to include(match(/contains invalid value/))
      end
    end

    context 'with nil or non-hash inputs' do
      it 'returns empty for nil content' do
        expect(described_class.validate_content(nil, {})).to be_empty
      end

      it 'returns empty for nil schema' do
        expect(described_class.validate_content({}, nil)).to be_empty
      end
    end
  end
end
