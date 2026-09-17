# lexer.rb — Лексичний аналізатор мови RB2
#
# Виконує лексичний аналіз окремим проходом (розд. 2 специфікації):
# розбиває текст програми на послідовність токенів Token(type, value, line).
# Пробільні символи та коментарі відкидаються; кінець рядка передається
# синтаксичному аналізатору як токен :eol, оскільки в RB2 він відіграє
# роль роздільника інструкцій (розд. 2.7).

module RB2
  class RB2Error < StandardError; end

  Token = Struct.new(:type, :value, :line) do
    def to_s
      "#{type}(#{value.inspect})@#{line}"
    end
  end

  class Lexer
    KEYWORDS = %w[if elsif else end while until do for in break next
                  true false gets puts print].freeze

    # 'and', 'or', 'not' розпізнаються окремо — одразу як логічні
    # оператори (токени :and_op, :or_op, :not_op), щоб парсер не мусив
    # відрізняти їх від символьних форм && || !.
    WORD_OPERATORS = { 'and' => :and_op, 'or' => :or_op, 'not' => :not_op }.freeze

    def initialize(source)
      @src = source
      @len = source.length
      @pos = 0
      @line = 1
    end

    def tokenize
      tokens = []
      loop do
        tok = next_token
        tokens << tok
        break if tok.type == :eof
      end
      tokens
    end

    private

    def peek(offset = 0)
      i = @pos + offset
      i < @len ? @src[i] : nil
    end

    def advance_char
      c = @src[@pos]
      @pos += 1
      c
    end

    def next_token
      skip_ignorable

      return Token.new(:eof, nil, @line) if @pos >= @len

      c = peek

      return lex_eol      if c == "\n" || c == "\r"
      return lex_number   if digit?(c)
      return lex_ident    if letter?(c) || c == '_'
      return lex_string   if c == '"'

      lex_operator
    end

    # Пробіли/табуляції та коментарі '#...' до кінця рядка відкидаються
    # без породження токенів (розд. 2.1, 2.2).
    def skip_ignorable
      loop do
        c = peek
        if c == ' ' || c == "\t"
          advance_char
        elsif c == '#'
          advance_char while peek && peek != "\n" && peek != "\r"
        else
          break
        end
      end
    end

    def lex_eol
      line = @line
      if peek == "\r" && peek(1) == "\n"
        advance_char; advance_char
      else
        advance_char
      end
      @line += 1
      Token.new(:eol, "\n", line)
    end

    def digit?(c) = c && c >= '0' && c <= '9'
    def letter?(c) = c && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))

    # IntNumb / RealNumb (розд. 2.5). Дійсна константа вимагає цифр по
    # обидва боки крапки, тому "1..10" коректно розбивається на
    # intnum(1), range_op(..), intnum(10), а не намагається зчитати "1."
    def lex_number
      line = @line
      start = @pos
      advance_char while digit?(peek)

      if peek == '.' && digit?(peek(1))
        advance_char # '.'
        advance_char while digit?(peek)
        return Token.new(:realnum, @src[start...@pos], line)
      end

      Token.new(:intnum, @src[start...@pos], line)
    end

    # Ident = (Letter|'_') {Letter|Digit|'_'} (розд. 2.4), з перевіркою
    # на ключові слова, логічні оператори-слова та логічні константи.
    def lex_ident
      line = @line
      start = @pos
      advance_char while letter?(peek) || digit?(peek) || peek == '_'
      word = @src[start...@pos]

      if word == 'true' || word == 'false'
        Token.new(:boolval, word, line)
      elsif WORD_OPERATORS.key?(word)
        Token.new(WORD_OPERATORS[word], word, line)
      elsif KEYWORDS.include?(word)
        Token.new(:keyword, word, line)
      else
        Token.new(:id, word, line)
      end
    end

    # StrConst = '"' {AnyCharExceptQuoteAndEol} '"' (розд. 2.5)
    def lex_string
      line = @line
      advance_char # відкривна лапка
      start = @pos
      while peek && peek != '"' && peek != "\n" && peek != "\r"
        advance_char
      end
      raise RB2Error, "Лексична помилка (рядок #{line}): незакритий рядковий літерал" unless peek == '"'
      text = @src[start...@pos]
      advance_char # закривна лапка
      Token.new(:strval, text, line)
    end

    # Спеціальні символи (розд. 2.3): застосовується правило
    # найдовшого збігу для двосимвольних операторів.
    TWO_CHAR = {
      '**' => :pow_op,
      '==' => :rel_op, '!=' => :rel_op, '<=' => :rel_op, '>=' => :rel_op,
      '+=' => :assign_op, '-=' => :assign_op, '*=' => :assign_op, '/=' => :assign_op,
      '&&' => :and_op, '||' => :or_op,
      '..' => :range_op,
    }.freeze

    ONE_CHAR = {
      '=' => :assign_op,
      '<' => :rel_op, '>' => :rel_op,
      '+' => :add_op, '-' => :add_op,
      '*' => :mult_op, '/' => :mult_op, '%' => :mult_op,
      '!' => :not_op,
      '(' => :brackets_op, ')' => :brackets_op,
      ',' => :punct, ';' => :punct, '|' => :punct,
      '.' => :dot,
    }.freeze

    def lex_operator
      line = @line
      two = peek.to_s + peek(1).to_s
      if TWO_CHAR.key?(two)
        advance_char; advance_char
        return Token.new(TWO_CHAR[two], two, line)
      end

      one = peek
      if ONE_CHAR.key?(one)
        advance_char
        return Token.new(ONE_CHAR[one], one, line)
      end

      raise RB2Error, "Лексична помилка (рядок #{line}): неприпустимий символ #{one.inspect}"
    end
  end
end
