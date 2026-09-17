#!/usr/bin/env ruby
# main.rb — точка входу транслятора мови RB2
#
# Використання:
#   ruby main.rb program.rb2
#
# Виконує повний цикл трансляції: лексичний аналіз (Lexer) окремим
# проходом -> синтаксичний аналіз (Parser), що будує АСД -> виконання
# (Interpreter), що обходить АСД і взаємодіє зі стандартним потоком
# введення/виведення (розд. 1.1, 7 специфікації).

require_relative 'lexer'
require_relative 'parser'
require_relative 'interpreter'

def main
  path = ARGV[0]
  if path.nil?
    warn "Використання: ruby main.rb <файл.rb2>"
    exit 1
  end

  unless File.exist?(path)
    warn "Файл не знайдено: #{path}"
    exit 1
  end

  source = File.read(path)

  tokens = RB2::Lexer.new(source).tokenize
  ast = RB2::Parser.new(tokens).parse_program
  RB2::Interpreter.new.run(ast)
rescue RB2::RB2Error => e
  warn e.message
  exit 1
end

main if __FILE__ == $PROGRAM_NAME
