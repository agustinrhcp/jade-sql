require 'spec_helper'

require 'jade'
require 'jade/module_loader'
require 'jade-sql'

module Jade
  describe 'Sql.Decimal' do
    include_context 'with test compiler'

    before do
      test_compiler.require('app', <<~JADE)
        module App exposing (
          encoded,
          mk_exponent,
          mk_mantissa,
          parse_exponent,
          parse_mantissa,
          parse_ok,
        )

        import Sql.Decimal exposing (Decimal, decimal, exponent, mantissa, parse)
        import Encode exposing (encode)
        import Decode exposing (Value)


        def mk_mantissa -> Int
          mantissa(decimal(175, -3))
        end


        def mk_exponent -> Int
          exponent(decimal(175, -3))
        end


        def parse_mantissa(s: String) -> Int
          parse(s)
            |> Maybe.map(mantissa)
            |> Maybe.with_default(0)
        end


        def parse_exponent(s: String) -> Int
          parse(s)
            |> Maybe.map(exponent)
            |> Maybe.with_default(0)
        end


        def parse_ok(s: String) -> Bool
          case parse(s)
          in Just(_) then True
          in Nothing then False
          end
        end


        def encoded(m: Int, e: Int) -> Value
          encode(decimal(m, e))
        end
      JADE
    end

    it 'exposes mantissa and exponent accessors' do
      expect(App::Internal.mk_mantissa).to eql 175
      expect(App::Internal.mk_exponent).to eql(-3)
    end

    it 'parses the <mantissa>e<exponent> wire form' do
      expect(App::Internal.parse_mantissa("175e-3")).to eql 175
      expect(App::Internal.parse_exponent("175e-3")).to eql(-3)
      expect(App::Internal.parse_mantissa("-1250e-2")).to eql(-1250)
    end

    it 'rejects malformed wire forms' do
      expect(App::Internal.parse_ok("175e-3")).to be true
      expect(App::Internal.parse_ok("nope")).to be false
      expect(App::Internal.parse_ok("1e2e3")).to be false
    end

    it 'encodes to the exact wire form (no Float)' do
      expect(App::Internal.encoded(175, -3)).to eql "175e-3"
      expect(App::Internal.encoded(-1250, -2)).to eql "-1250e-2"
    end
  end

  describe 'Sql.Decimal arithmetic (BigDecimal-style)' do
    include_context 'with test compiler'

    before do
      test_compiler.require('app', <<~JADE)
        module App exposing (
          add_e,
          add_m,
          div_hi,
          div_lo,
          div_neg,
          divzero,
          half,
          mul_e,
          mul_m,
          round_e,
          round_m,
          round_neg,
          tf,
          ti_int,
          ti_neg,
          ti_pos,
        )

        import Sql.Decimal exposing (Decimal, decimal, div, exponent, mantissa, round, to_float, to_i)


        def addd -> Decimal
          decimal(175, -3) + decimal(125, -1)
        end


        def add_m -> Int
          mantissa(addd)
        end


        def add_e -> Int
          exponent(addd)
        end


        def muld -> Decimal
          decimal(175, -3) * decimal(2, 0)
        end


        def mul_m -> Int
          mantissa(muld)
        end


        def mul_e -> Int
          exponent(muld)
        end


        def div_lo -> Int
          mantissa(div(decimal(1, 0), decimal(3, 0), 5))
        end


        def div_hi -> Int
          mantissa(div(decimal(2, 0), decimal(3, 0), 5))
        end


        def div_neg -> Int
          mantissa(div(decimal(0 - 2, 0), decimal(3, 0), 5))
        end


        def half -> Float
          to_float(decimal(1, 0) / decimal(2, 0))
        end


        def rounded -> Decimal
          round(decimal(12675, -3), 2)
        end


        def round_m -> Int
          mantissa(rounded)
        end


        def round_e -> Int
          exponent(rounded)
        end


        def round_neg -> Int
          mantissa(round(decimal(0 - 25, -1), 0))
        end


        def ti_pos -> Int
          to_i(decimal(12675, -3))
        end


        def ti_neg -> Int
          to_i(decimal(0 - 12675, -3))
        end


        def ti_int -> Int
          to_i(decimal(175, 2))
        end


        def tf -> Float
          to_float(decimal(175, -3))
        end


        def divzero -> Int
          mantissa(div(decimal(1, 0), decimal(0, 0), 5))
        end
      JADE
    end

    it 'adds exactly, aligning exponents' do
      expect([App::Internal.add_m, App::Internal.add_e]).to eql [12675, -3]
    end

    it 'multiplies exactly' do
      expect([App::Internal.mul_m, App::Internal.mul_e]).to eql [350, -3]
    end

    it 'divides half-up to the given scale (ties away from zero, incl. negatives)' do
      expect(App::Internal.div_lo).to eql 33333
      expect(App::Internal.div_hi).to eql 66667
      expect(App::Internal.div_neg).to eql(-66667)
    end

    it 'supports the / operator (rounds, never infinite)' do
      expect(App::Internal.half).to eql 0.5
    end

    it 'rounds half-up to a scale (-2.5 -> -3, away from zero)' do
      expect([App::Internal.round_m, App::Internal.round_e]).to eql [1268, -2]
      expect(App::Internal.round_neg).to eql(-3)
    end

    it 'to_i truncates toward zero' do
      expect(App::Internal.ti_pos).to eql 12
      expect(App::Internal.ti_neg).to eql(-12)
      expect(App::Internal.ti_int).to eql 17500
    end

    it 'to_float converts' do
      expect(App::Internal.tf).to eql 0.175
    end

    it 'raises on division by zero (like BigDecimal#div)' do
      expect { App::Internal.divzero }.to raise_error(ZeroDivisionError)
    end
  end
end
