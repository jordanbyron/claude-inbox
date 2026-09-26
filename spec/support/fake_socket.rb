# frozen_string_literal: true

# A connection for the Remote specs: it reads the request it
# was given and keeps whatever is written back.
class FakeSocket
  attr_reader :written

  def initialize(request)
    @input = StringIO.new(request.b)
    @written = +"".b
  end

  def read_nonblock(size, exception: true) = @input.read_nonblock(size, exception: exception)

  def write(data) = @written << data.b
end

# What came back from Listener#handle or Start#call, parsed. `note` is
# Start's, for N.
Reply = Struct.new(:status, :headers, :body, :written, :note) do
  def json = JSON.parse(body)
end
