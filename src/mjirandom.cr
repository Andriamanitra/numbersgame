module Mjirandom
  extend self

  # return a list of k integers (no duplicates) from range first..last
  def sample(first : Int32, last : Int32, k : Int32) : Array(Int32)
    first, last = last, first if first > last

    n = last - first + 1  # population size

    unless 0 <= k <= n
      raise Exception.new("Sample size can't be greater than population size or negative")
    end

    setsize = 21
    setsize += 4 ** Math.log(k * 3, 4).ceil.to_i if k > 5

    if n <= setsize
      return (first..last).to_a.sample(k)
    else
      selected = Set(Int32).new
      return Array(Int32).new(k) do |i|
        j = rand(n)
        while selected.includes? j
          j = rand(n)
        end
        selected << j
        first + j
      end
    end
  end
end
