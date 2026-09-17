# ast.rb — вузли абстрактного синтаксичного дерева мови RB2

module RB2
  Node = Struct.new(:type, :attrs, :line) do
    def initialize(type, attrs = {}, line = nil)
      super(type, attrs, line)
    end

    def [](key) = attrs[key]
    def to_s = "#{type}#{attrs}"
  end

  def self.node(type, line, **attrs) = Node.new(type, attrs, line)
end
