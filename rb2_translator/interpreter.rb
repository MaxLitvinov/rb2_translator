# interpreter.rb — Семантичний аналіз і виконання програм мовою RB2
#
# Виконує програму методом обходу АСД (tree-walking interpreter).
# Семантичні перевірки (розд. 3.2, 4.4, 4.6, 5.4, 5.7, табл. 7) та
# обчислення значень виконуються за одним проходом: помилка типів чи
# використання невизначеної змінної діагностується в момент, коли
# відповідний вузол дерева обчислюється.
#
# Тип змінної/значення представлено символом :Integer, :Float,
# :Boolean або :String (розд. 3.1).

module RB2
  class BreakSignal < StandardError; end
  class NextSignal < StandardError; end

  class Interpreter
    def initialize(input: $stdin, output: $stdout)
      @vars = {}   # name => { type: Symbol, value: Object }
      @input = input
      @output = output
      @loop_depth = 0 # для перевірки, що break/next використані всередині циклу
    end

    def run(program_node)
      exec_block(program_node[:stmts])
    end

    private

    # ---------- виконання інструкцій ----------

    def exec_block(stmts)
      stmts.each { |s| exec_stmt(s) }
    end

    def exec_stmt(node)
      case node.type
      when :assign then exec_assign(node)
      when :out then exec_out(node)
      when :if then exec_if(node)
      when :while_until then exec_while(node)
      when :for then exec_for(node)
      when :break
        semantic_error(node, "інструкція break використана поза тілом циклу") if @loop_depth.zero?
        raise BreakSignal
      when :next
        semantic_error(node, "інструкція next використана поза тілом циклу") if @loop_depth.zero?
        raise NextSignal
      else
        raise RB2Error, "Внутрішня помилка: невідомий вузол інструкції #{node.type}"
      end
    end

    # Assign = Ident AssignOp Expression (розд. 5.1)
    def exec_assign(node)
      name = node[:name]
      value, vtype = eval_expr(node[:expr])

      if node[:op] == '='
        if @vars.key?(name)
          existing = @vars[name]
          value = check_and_coerce_assign(existing[:type], vtype, value, node)
          existing[:value] = value
        else
          @vars[name] = { type: vtype, value: value }
        end
      else
        # складене присвоєння v op= E еквівалентне v = v op E (розд. 5.1);
        # змінна має вже існувати і мати значення.
        unless @vars.key?(name)
          semantic_error(node, "змінна '#{name}' використовується у складеному присвоєнні до першого простого присвоєння")
        end
        existing = @vars[name]
        binop = node[:op][0] # '+', '-', '*' або '/'
        new_value, new_type = apply_binop(binop, existing[:value], existing[:type], value, vtype, node)
        new_value = check_and_coerce_assign(existing[:type], new_type, new_value, node)
        existing[:value] = new_value
      end
    end

    # Перевіряє узгодженість типу при присвоєнні змінній, що вже існує
    # (розд. 3.2): типи мають збігатись, дозволене лише неявне
    # приведення Integer -> Float (розд. 4.6).
    def check_and_coerce_assign(existing_type, new_type, value, node)
      return value if existing_type == new_type
      return value.to_f if existing_type == :Float && new_type == :Integer

      semantic_error(node, "неможливо присвоїти значення типу #{new_type} змінній типу #{existing_type}")
    end

    # Out = (puts|print) ['('] ExprList [')'] (розд. 5.3)
    def exec_out(node)
      values = node[:exprs].map { |e| eval_expr(e) }
      if node[:kind] == 'puts'
        values.each { |v, t| @output.puts(format_value(v, t)) }
      else # print
        values.each { |v, t| @output.print(format_value(v, t)) }
      end
    end

    # IfStatement (розд. 5.4)
    def exec_if(node)
      node[:branches].each do |cond, body|
        val, type = eval_expr(cond)
        semantic_error(node, "умова інструкції розгалуження має тип #{type}, очікувався Boolean") unless type == :Boolean
        if val
          exec_block(body)
          return
        end
      end
      exec_block(node[:else_body]) if node[:else_body]
    end

    # WhileStatement: while / until (розд. 5.5)
    def exec_while(node)
      @loop_depth += 1
      loop do
        val, type = eval_expr(node[:cond])
        semantic_error(node, "умова циклу #{node[:kind]} має тип #{type}, очікувався Boolean") unless type == :Boolean
        cond_true = node[:kind] == 'while' ? val : !val
        break unless cond_true

        begin
          exec_block(node[:body])
        rescue NextSignal
          # переходимо до повторної перевірки умови
        rescue BreakSignal
          break
        end
      end
    ensure
      @loop_depth -= 1
    end

    # ForStatement (розд. 5.6)
    def exec_for(node)
      from_v, from_t = eval_expr(node[:from])
      to_v, to_t = eval_expr(node[:to])
      semantic_error(node, "межі діапазону for мають бути типу Integer") unless from_t == :Integer && to_t == :Integer

      if @vars.key?(node[:var])
        semantic_error(node, "параметр циклу '#{node[:var]}' має тип #{@vars[node[:var]][:type]}, очікувався Integer") unless @vars[node[:var]][:type] == :Integer
      else
        @vars[node[:var]] = { type: :Integer, value: nil }
      end

      @loop_depth += 1
      i = from_v
      while i <= to_v
        @vars[node[:var]][:value] = i
        begin
          exec_block(node[:body])
        rescue NextSignal
          # переходимо до наступної ітерації
        rescue BreakSignal
          break
        end
        i += 1
      end
    ensure
      @loop_depth -= 1
    end

    # ---------- обчислення виразів ----------
    # Повертає пару [значення, тип]

    def eval_expr(node)
      case node.type
      when :intlit  then [node[:value], :Integer]
      when :reallit then [node[:value], :Float]
      when :strlit  then [node[:value], :String]
      when :boollit then [node[:value], :Boolean]
      when :var     then eval_var(node)
      when :gets    then eval_gets(node)
      when :unary   then eval_unary(node)
      when :not     then eval_not(node)
      when :logic   then eval_logic(node)
      when :relop   then eval_relop(node)
      when :binop
        l, lt = eval_expr(node[:left])
        r, rt = eval_expr(node[:right])
        apply_binop(node[:op], l, lt, r, rt, node)
      else
        raise RB2Error, "Внутрішня помилка: невідомий вузол виразу #{node.type}"
      end
    end

    def eval_var(node)
      entry = @vars[node[:name]]
      semantic_error(node, "використання змінної '#{node[:name]}', що не набула значення") unless entry
      [entry[:value], entry[:type]]
    end

    # Input = gets ['.' ConvMethod] (розд. 5.2)
    def eval_gets(node)
      line = @input.gets
      runtime_error(node, "неможливо прочитати вхідні дані (кінець потоку)") if line.nil?
      text = line.chomp

      case node[:conv]
      when nil
        [text, :String]
      when 'to_i'
        begin
          [Integer(text.strip), :Integer]
        rescue ArgumentError
          runtime_error(node, "введене значення \"#{text}\" не інтерпретується як Integer")
        end
      when 'to_f'
        begin
          [Float(text.strip), :Float]
        rescue ArgumentError
          runtime_error(node, "введене значення \"#{text}\" не інтерпретується як Float")
        end
      end
    end

    def numeric?(t) = t == :Integer || t == :Float

    # Унарні оператори (розд. 4.3, табл. 6)
    def eval_unary(node)
      v, t = eval_expr(node[:operand])
      semantic_error(node, "унарний оператор '#{node[:op]}' застосований до операнда типу #{t}") unless numeric?(t)
      v = node[:op] == '-' ? -v : v
      [v, t]
    end

    # Логічне заперечення ! / not (розд. 4.3, 4.5)
    def eval_not(node)
      v, t = eval_expr(node[:operand])
      semantic_error(node, "оператор заперечення застосований до операнда типу #{t}, очікувався Boolean") unless t == :Boolean
      [!v, :Boolean]
    end

    # && (and) / || (or) зі скороченим обчисленням (розд. 4.5)
    def eval_logic(node)
      l, lt = eval_expr(node[:left])
      semantic_error(node, "лівий операнд логічного оператора має тип #{lt}, очікувався Boolean") unless lt == :Boolean

      if node[:op] == :or
        return [true, :Boolean] if l
      else # :and
        return [false, :Boolean] unless l
      end

      r, rt = eval_expr(node[:right])
      semantic_error(node, "правий операнд логічного оператора має тип #{rt}, очікувався Boolean") unless rt == :Boolean
      [node[:op] == :or ? (l || r) : (l && r), :Boolean]
    end

    # Оператори відношення (розд. 4.4)
    def eval_relop(node)
      l, lt = eval_expr(node[:left])
      r, rt = eval_expr(node[:right])

      if numeric?(lt) && numeric?(rt)
        lf, rf = l.to_f, r.to_f
        result = compare(node[:op], lf, rf, node)
      elsif lt == :Boolean && rt == :Boolean
        result = compare(node[:op], l ? 1 : 0, r ? 1 : 0, node)
      elsif lt == :String && rt == :String
        result = compare(node[:op], l, r, node)
      else
        semantic_error(node, "непорівнювані типи операндів: #{lt} та #{rt}")
      end

      [result, :Boolean]
    end

    def compare(op, l, r, node)
      case op
      when '==' then l == r
      when '!=' then l != r
      when '<'  then l < r
      when '<=' then l <= r
      when '>'  then l > r
      when '>=' then l >= r
      else semantic_error(node, "невідомий оператор відношення #{op}")
      end
    end

    # Бінарні арифметичні оператори та конкатенація (розд. 4.3, табл. 5)
    def apply_binop(op, l, lt, r, rt, node)
      if op == '+' && lt == :String && rt == :String
        return [l + r, :String]
      end
      if op == '**'
        return eval_pow(l, lt, r, rt, node)
      end

      unless numeric?(lt) && numeric?(rt)
        semantic_error(node, "оператор '#{op}' не визначений для типів #{lt} та #{rt}")
      end

      case op
      when '+', '-', '*'
        if lt == :Float || rt == :Float
          [send_arith(op, l.to_f, r.to_f), :Float]
        else
          [send_arith(op, l, r), :Integer]
        end
      when '/'
        runtime_error(node, "ділення на нуль") if r.zero?
        if lt == :Integer && rt == :Integer
          [(l.to_f / r).truncate, :Integer]
        else
          [l.to_f / r.to_f, :Float]
        end
      when '%'
        unless lt == :Integer && rt == :Integer
          semantic_error(node, "оператор '%' визначений тільки для Integer та Integer")
        end
        runtime_error(node, "ділення на нуль (%)") if r.zero?
        [l % r, :Integer]
      else
        semantic_error(node, "невідомий оператор #{op}")
      end
    end

    def send_arith(op, l, r)
      case op
      when '+' then l + r
      when '-' then l - r
      when '*' then l * r
      end
    end

    # Піднесення до степеня (розд. 4.3, табл. 5): Integer**Integer(>=0)
    # дає Integer, усі інші числові комбінації — Float.
    def eval_pow(l, lt, r, rt, node)
      unless numeric?(lt) && numeric?(rt)
        semantic_error(node, "оператор '**' не визначений для типів #{lt} та #{rt}")
      end
      if lt == :Integer && rt == :Integer && r >= 0
        [l**r, :Integer]
      else
        [l.to_f**r.to_f, :Float]
      end
    end

    # ---------- форматування виведення (розд. 5.3) ----------

    def format_value(value, type)
      case type
      when :Boolean then value ? 'true' : 'false'
      when :String then value
      else value.to_s
      end
    end

    # ---------- помилки ----------

    def semantic_error(node, msg)
      raise RB2Error, "Семантична помилка (рядок #{node.line}): #{msg}"
    end

    def runtime_error(node, msg)
      raise RB2Error, "Помилка часу виконання (рядок #{node.line}): #{msg}"
    end
  end
end
