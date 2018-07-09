// Package hamming handles hamming distance calculations
package hamming

import "errors"

// Distance should calculate the hamming distance between two sequences
func Distance(a, b string) (int, error) {
	if len(a) != len(b) {
		return -1, errors.New("Length mismatch")
	}

	count := 0
	for i := range a {
		if a[i] != b[i] {
			count++
		}
	}

	return count, nil
}



	//print("There is an err", err)

}
