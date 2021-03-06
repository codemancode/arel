module Arel
  module Visitors
    class SQLAnywhere < Arel::Visitors::ToSql
      private

      def visit_Arel_Nodes_SelectStatement o
        o = order_hacks(o)

        is_distinct = using_distinct?(o)
          
        o.limit = 1000000 if (o.offset && !o.limit)
        o.limit = o.limit.expr if(o.limit.is_a?(Arel::Nodes::Limit))
        o.limit = o.limit if(o.limit.is_a?(Fixnum))

        [
          "SELECT",
          ("DISTINCT" if is_distinct),
          ("TOP #{o.limit}" if o.limit),
          (visit_Arel_Nodes_Offset(o.offset) if o.offset),
          o.cores.map { |x| visit_Arel_Nodes_SelectCore x }.join,
          ("ORDER BY #{o.orders.map { |x| visit x }.join(', ')}" unless o.orders.empty?),
                #("LIMIT #{o.limit}" if o.limit),
                #(visit(o.offset) if o.offset),
          (visit(o.lock) if o.lock),
        ].compact.join ' '
      end

      def visit_Arel_Nodes_SelectCore o
        [
          "#{o.projections.map { |x| visit x }.join ', '}",
          ("FROM #{visit o.source}" if o.source), # Joins
          ("WHERE #{o.wheres.map { |x| visit x }.join ' AND ' }" unless o.wheres.empty?),
          ("GROUP BY #{o.groups.map { |x| visit x }.join ', ' }" unless o.groups.empty?),
          (visit(o.having) if o.having),
        ].compact.join ' '
      end

      def visit_Arel_Nodes_Group o
        expr = o.expr.clone
        if expr.class == Arel::Nodes::NamedFunction
          expr.alias = nil
        end
        visit expr
      end

      def visit_Arel_Nodes_Offset o
        "START AT #{visit(o.expr) + 1}"
      end
      
      def visit_Arel_Nodes_True o
        "1=1"
      end
      
      def visit_Arel_Nodes_False o
        "1=0"
      end
      
      def visit_Arel_Nodes_Matches o
        # The version in arel cannot like integer columns
        left = visit o.left # This method sets last column
        # If last column was left, visit o.right would return 0
        self.last_column = nil
        "#{left} LIKE #{visit o.right}"
      end
    
      def using_distinct?(o)
        o.cores.any? do |core|
          core.set_quantifier.class == Arel::Nodes::Distinct
        end
      end      

      # The functions (order_hacks, split_order_string) are based on the Oracle Enhacned ActiveRecord driver maintained by Raimonds Simanovskis (2010)
      # (https://github.com/rsim/oracle-enhanced)

      ###
      # Hacks for the order clauses
      def order_hacks o
        return o if o.orders.empty?
        return o unless o.cores.any? do |core|
          core.projections.any? do |projection|
            /DISTINCT.*FIRST_VALUE/ === projection
          end
        end
        # Previous version with join and split broke ORDER BY clause
        # if it contained functions with several arguments (separated by ',').
        #
        # orders   = o.orders.map { |x| visit x }.join(', ').split(',')
        orders   = o.orders.map do |x|
          string = visit x
          if string.include?(',')
            split_order_string(string)
          else
            string
          end
        end.flatten
        o.orders = []
        orders.each_with_index do |order, i|
          o.orders <<
            Nodes::SqlLiteral.new("alias_#{i}__#{' DESC' if /\bdesc$/i === order}")
        end
        o
      end

      # Split string by commas but count opening and closing brackets
      # and ignore commas inside brackets.
      def split_order_string(string)
        array = []
        i = 0
        string.split(',').each do |part|
          if array[i]
            array[i] << ',' << part
          else
            # to ensure that array[i] will be String and not Arel::Nodes::SqlLiteral
            array[i] = '' << part
          end
          i += 1 if array[i].count('(') == array[i].count(')')
        end
        array
      end
    end
  end
end