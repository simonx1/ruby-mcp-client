# frozen_string_literal: true

require 'zlib'

module MCPClient
  module HttpTransportBase
    # Inflation of peer-supplied gzip bytes under an expansion bound. The peer
    # controls the compression ratio, so the bound is applied to the pieces
    # zlib produces as it produces them: a body that expands far past the
    # ceiling is stopped at the first piece that crosses it, never allocated
    # in full and then measured.
    module BoundedInflate
      module_function

      # @param inflater [Zlib::Inflate] the stream the bytes belong to
      # @param bytes [String] gzip bytes as they arrived
      # @param limit [Integer, nil] ceiling on the inflated size, nil for none
      # @param inflated_so_far [Integer] bytes this stream already produced
      # @return [String, nil] the text these bytes expand to; nil once the
      #   expansion would cross the limit
      def inflate(inflater, bytes, limit, inflated_so_far = 0)
        text = +''.b
        over = ->(piece) { limit && inflated_so_far + text.bytesize + piece.bytesize > limit }
        catch(:over_the_bound) do
          inflater.inflate(bytes) do |piece|
            throw :over_the_bound if over.call(piece)

            text << piece
          end
          # zlib hands over full pieces as it fills them; what is left of a
          # stream that has not ended stays in its buffer until asked for.
          tail = inflater.flush_next_out
          throw :over_the_bound if over.call(tail)

          return text << tail
        end
        nil
      end
    end
  end
end
