package main

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
)

func main() {
	query := url.QueryEscape("q") + "=" + url.QueryEscape("hello world") + "&" + url.QueryEscape("lang") + "=" + url.QueryEscape("en")
	req, err := http.NewRequest("GET", "https://api.example.com/search"+"?"+query, nil)
	if err != nil {
		panic(err)
	}
	req.Header.Set("Accept", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	fmt.Println(resp.StatusCode, string(body))
}

// not translated: -s, -S
