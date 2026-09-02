# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # Dialect selection: the `$schema` a document (or an embedded resource
    # root) declares, its canonical supported form, and the problems an
    # unusable declaration reports. Extended into SchemaValidator, so the
    # methods are its own.
    module Dialects
      # The dialect a schema declares, or the default.
      # @param schema [Object] the schema
      # @return [String] the `$schema` value (without a trailing `#`), or DEFAULT_DIALECT
      def dialect(schema)
        return DEFAULT_DIALECT unless schema.is_a?(Hash)
        return DEFAULT_DIALECT unless schema.key?('$schema') || schema.key?(:$schema)

        declared = schema.key?('$schema') ? schema['$schema'] : schema[:$schema]
        # A declaration that is present but unusable is not the default.
        return nil unless declared.is_a?(String) && !declared.empty?

        declared.sub(/#\z/, '')
      end

      # The supported dialect a declared URI stands for (scheme-insensitive),
      # or nil.
      # @param uri [String]
      # @return [String, nil]
      def canonical_dialect(uri)
        canonical = uri.sub(/#\z/, '').sub(%r{\Ahttps?://}, '')
        SUPPORTED_DIALECTS.find { |d| d.sub(%r{\Ahttps?://}, '') == canonical }
      end

      # @param uri [String]
      # @return [Boolean]
      def supported_dialect?(uri)
        !canonical_dialect(uri).nil?
      end

      # The dialect in force at a schema object: an embedded resource root (a
      # subschema whose `$id` is a URI) may declare its own `$schema`, which
      # is that resource's dialect (JSON Schema 2020-12 Core Section 8.1.1);
      # anywhere else the inherited dialect applies (a `$schema` that is not
      # at a resource root is ignored).
      # @param schema [Hash]
      # @param inherited [String, nil] the enclosing resource's dialect
      # @return [String, nil] the canonical dialect, or nil when the embedded
      #   declaration is malformed or unsupported
      def embedded_dialect(schema, inherited)
        return inherited unless resource_root?(schema, inherited) && schema.key?('$schema')

        declared = dialect(schema)
        declared && canonical_dialect(declared)
      end

      # @return [String, nil] why an embedded resource's `$schema` is unusable
      def embedded_dialect_problem(schema)
        declared = dialect(schema)
        return 'embedded resource $schema must be a non-empty string naming the dialect' if declared.nil?
        return nil if supported_dialect?(declared)

        "embedded resource dialect #{clip(declared.inspect)} is not supported " \
          "(supported: #{SUPPORTED_DIALECTS.join(', ')})"
      end
    end
  end
end
