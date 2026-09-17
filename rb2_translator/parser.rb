# parser.rb — Синтаксичний аналізатор мови RB2 (метод рекурсивного спуску)
#
# Реалізує граматику з розд. 8 специфікації. Граматика виразів не містить
# лівої рекурсії (правило PowTerm — навмисно праворекурсивне для **),
# тому весь розбір виконується методом рекурсивного спуску без
# додаткових перетворень.

require_relative 'ast'

module RB2
  class Parser
    def initialize(tokens)
      @tokens = tokens
      @pos = 0
    end

    # Program = [Terminator] StatementList [Terminator] EndOfText
    def parse_program
      skip_terminators
      stmts = parse_statement_list(%w[])
      expect_type(:eof)
      RB2.node(:program, 1, stmts: stmts)
    end

    private

    # ---------- допоміжні методи роботи з потоком токенів ----------

    def cur = @tokens[@pos]
    def cur_type = cur.type
    def cur_line = cur.line

    def keyword?(word) = cur_type == :keyword && cur.value == word

    def advance
      t = cur
      @pos += 1 unless t.type == :eof
      t
    end

    def expect_type(type)
      raise_syntax("очікувався токен #{type}, отримано #{cur}") unless cur_type == type
      advance
    end

    def expect_keyword(word)
      raise_syntax("очікувалось ключове слово '#{word}', отримано #{cur}") unless keyword?(word)
      advance
    end

    def raise_syntax(msg)
      raise RB2Error, "Синтаксична помилка (рядок #{cur_line}): #{msg}"
    end

    # Terminator = (';' | eol) {';' | eol} — приймається як 0 або більше
    # роздільників: це узгоджує граматику з практикою однорядкового
    # запису інструкцій (do ... end в одному рядку, розд. 5.5, 5.6),
    # де формальний Terminator між ключовими словами не обов'язковий.
    def skip_terminators
      advance while cur_type == :eol || (cur_type == :punct && cur.value == ';')
    end

    # ---------- StatementList / Statement ----------

    # end_words — ключові слова, що завершують поточний блок
    # (наприклад ['end'] або ['elsif','else','end'])
    def parse_statement_list(end_words)
      stmts = []
      skip_terminators
      until cur_type == :eof || (cur_type == :keyword && end_words.include?(cur.value))
        stmts << parse_statement
        skip_terminators
      end
      stmts
    end

    def parse_statement
      line = cur_line
      if cur_type == :id
        parse_assign
      elsif keyword?('puts') || keyword?('print')
        parse_out
      elsif keyword?('if')
        parse_if
      elsif keyword?('while') || keyword?('until')
        parse_while
      elsif keyword?('for')
        parse_for
      elsif keyword?('break')
        advance
        RB2.node(:break, line)
      elsif keyword?('next')
        advance
        RB2.node(:next, line)
      else
        raise_syntax("неочікуваний початок інструкції: #{cur}")
      end
    end

    # Assign = Ident AssignOp Expression
    def parse_assign
      line = cur_line
      name = expect_type(:id).value
      op_tok = expect_type(:assign_op)
      expr = parse_expression
      RB2.node(:assign, line, name: name, op: op_tok.value, expr: expr)
    end

    # Out = (puts|print) ['('] ExprList [')']
    def parse_out
      line = cur_line
      kind = advance.value # 'puts' або 'print'
      has_paren = false
      if cur_type == :brackets_op && cur.value == '('
        advance
        has_paren = true
      end
      exprs = [parse_expression]
      while cur_type == :punct && cur.value == ','
        advance
        exprs << parse_expression
      end
      expect_bracket_close if has_paren
      RB2.node(:out, line, kind: kind, exprs: exprs)
    end

    def expect_bracket_close
      raise_syntax("очікувалась закривна дужка ')'") unless cur_type == :brackets_op && cur.value == ')'
      advance
    end

    # IfStatement = if Condition Terminator StatementList
    #               {elsif Condition Terminator StatementList}
    #               [else Terminator StatementList]
    #               end
    def parse_if
      line = cur_line
      expect_keyword('if')
      cond = parse_expression
      skip_terminators
      body = parse_statement_list(%w[elsif else end])
      branches = [[cond, body]]

      while keyword?('elsif')
        advance
        c = parse_expression
        skip_terminators
        b = parse_statement_list(%w[elsif else end])
        branches << [c, b]
      end

      else_body = nil
      if keyword?('else')
        advance
        skip_terminators
        else_body = parse_statement_list(%w[end])
      end

      expect_keyword('end')
      RB2.node(:if, line, branches: branches, else_body: else_body)
    end

    # WhileStatement = (while|until) Condition [do] Terminator StatementList end
    def parse_while
      line = cur_line
      kind = advance.value # 'while' або 'until'
      cond = parse_expression
      advance if keyword?('do')
      skip_terminators
      body = parse_statement_list(%w[end])
      expect_keyword('end')
      RB2.node(:while_until, line, kind: kind, cond: cond, body: body)
    end

    # ForStatement = for Ident in Range [do] Terminator StatementList end
    # Range = ArExpr1 '..' ArExpr2
    def parse_for
      line = cur_line
      expect_keyword('for')
      var = expect_type(:id).value
      expect_keyword('in')
      from = parse_expression
      expect_type(:range_op)
      to = parse_expression
      advance if keyword?('do')
      skip_terminators
      body = parse_statement_list(%w[end])
      expect_keyword('end')
      RB2.node(:for, line, var: var, from: from, to: to, body: body)
    end

    # ---------- Вирази (розд. 4.1, 8) ----------
    # Expression = OrExpr
    def parse_expression = parse_or

    # OrExpr = AndExpr {OrOp AndExpr}
    def parse_or
      node = parse_and
      while cur_type == :or_op
        line = cur_line
        advance
        right = parse_and
        node = RB2.node(:logic, line, op: :or, left: node, right: right)
      end
      node
    end

    # AndExpr = NotExpr {AndOp NotExpr}
    def parse_and
      node = parse_not
      while cur_type == :and_op
        line = cur_line
        advance
        right = parse_not
        node = RB2.node(:logic, line, op: :and, left: node, right: right)
      end
      node
    end

    # NotExpr = [NotOp] RelExpr
    def parse_not
      if cur_type == :not_op
        line = cur_line
        advance
        operand = parse_rel
        return RB2.node(:not, line, operand: operand)
      end
      parse_rel
    end

    # RelExpr = ArithmExpression [RelOp ArithmExpression]
    def parse_rel
      left = parse_arith
      if cur_type == :rel_op
        line = cur_line
        op = advance.value
        right = parse_arith
        return RB2.node(:relop, line, op: op, left: left, right: right)
      end
      left
    end

    # ArithmExpression = Term {AddOp Term}
    def parse_arith
      node = parse_term
      while cur_type == :add_op
        line = cur_line
        op = advance.value
        right = parse_term
        node = RB2.node(:binop, line, op: op, left: node, right: right)
      end
      node
    end

    # Term = PowTerm {MultOp PowTerm}
    def parse_term
      node = parse_pow
      while cur_type == :mult_op
        line = cur_line
        op = advance.value
        right = parse_pow
        node = RB2.node(:binop, line, op: op, left: node, right: right)
      end
      node
    end

    # PowTerm = Factor [PowOp PowTerm]  -- правоасоціативний
    def parse_pow
      left = parse_factor
      if cur_type == :pow_op
        line = cur_line
        advance
        right = parse_pow
        return RB2.node(:binop, line, op: '**', left: left, right: right)
      end
      left
    end

    # Factor = [Sign] Primary
    def parse_factor
      if cur_type == :add_op && (cur.value == '+' || cur.value == '-')
        line = cur_line
        sign = advance.value
        operand = parse_primary
        return RB2.node(:unary, line, op: sign, operand: operand)
      end
      parse_primary
    end

    # Primary = Ident | Const | '(' Expression ')' | Input
    def parse_primary
      line = cur_line
      case cur_type
      when :id
        RB2.node(:var, line, name: advance.value)
      when :intnum
        RB2.node(:intlit, line, value: advance.value.to_i)
      when :realnum
        RB2.node(:reallit, line, value: advance.value.to_f)
      when :strval
        RB2.node(:strlit, line, value: advance.value)
      when :boolval
        RB2.node(:boollit, line, value: advance.value == 'true')
      when :brackets_op
        raise_syntax("неочікуваний символ #{cur.value}") unless cur.value == '('
        advance
        e = parse_expression
        expect_bracket_close
        e
      when :keyword
        if cur.value == 'gets'
          advance
          conv = nil
          if cur_type == :dot
            advance
            m = expect_type(:id)
            raise_syntax("метод '#{m.value}' невідомий; очікувалось to_i або to_f") unless %w[to_i to_f].include?(m.value)
            conv = m.value
          end
          RB2.node(:gets, line, conv: conv)
        else
          raise_syntax("неочікуване ключове слово '#{cur.value}' у виразі")
        end
      else
        raise_syntax("неочікуваний токен у виразі: #{cur}")
      end
    end
  end
end
